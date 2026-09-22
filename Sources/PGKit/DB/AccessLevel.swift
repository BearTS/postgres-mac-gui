import Foundation

/// What a role may do in one database, expressed the way a person thinks about it.
///
/// Levels are implemented as membership in a per-database group role rather than as scattered
/// per-user grants. That makes a level reversible in two statements, auditable from
/// `pg_auth_members`, and automatically applicable to future tables via `ALTER DEFAULT PRIVILEGES`
/// on the group.
public enum AccessLevel: String, CaseIterable, Sendable, Identifiable, Codable {
    case noAccess
    case readOnly
    case readWrite
    case owner

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .noAccess:  return "No Access"
        case .readOnly:  return "Read Only"
        case .readWrite: return "Read / Write"
        case .owner:     return "Owner"
        }
    }

    public var explanation: String {
        switch self {
        case .noAccess:  return "Cannot connect to this database."
        case .readOnly:  return "Can connect and run SELECT on all tables, now and in future."
        case .readWrite: return "Can connect, read, and INSERT / UPDATE / DELETE, including on future tables."
        case .owner:     return "Full control of the database, including creating and dropping objects."
        }
    }

    public var symbolName: String {
        switch self {
        case .noAccess:  return "xmark.circle"
        case .readOnly:  return "eye"
        case .readWrite: return "pencil"
        case .owner:     return "crown"
        }
    }
}

/// What introspection actually found — which may not match any clean level.
public enum EffectiveAccess: Sendable, Equatable {
    case level(AccessLevel)
    /// Privileges that group membership does not explain, e.g. grants made by hand in psql.
    case custom(reasons: [String])

    public var level: AccessLevel? {
        if case .level(let level) = self { return level }
        return nil
    }

    public var label: String {
        switch self {
        case .level(let level): return level.label
        case .custom:           return "Custom"
        }
    }
}

/// Extra capabilities that can be added on top of Read / Write.
public struct AccessOptions: Sendable, Hashable, Codable {
    /// Lets the role create and alter tables — what an ORM or migration tool needs.
    public var canCreateObjects: Bool
    /// Adds TRUNCATE, REFERENCES and TRIGGER to the table grants.
    public var canTruncate: Bool

    public init(canCreateObjects: Bool = false, canTruncate: Bool = false) {
        self.canCreateObjects = canCreateObjects
        self.canTruncate = canTruncate
    }

    public static let `default` = AccessOptions()
}

/// Names the per-database group roles that carry each level.
public enum GroupRoleNaming {

    public static let prefix = "pgm"

    /// `pgm_<db>_ro`, sanitised to `[a-z0-9_]` and kept within Postgres' 63-byte NAMEDATALEN,
    /// falling back to a hash suffix when a long database name has to be truncated.
    public static func groupRole(database: String, level: AccessLevel) -> String? {
        guard let suffix = levelSuffix(level) else { return nil }
        let sanitized = sanitize(database)
        let candidate = "\(prefix)_\(sanitized)_\(suffix)"
        if candidate.utf8.count <= 63 { return candidate }

        let hash = shortHash(database)
        let fixedCost = prefix.utf8.count + 1 + 1 + hash.count + 1 + suffix.utf8.count  // pgm_ + _ + hash + _ + suffix
        let room = max(1, 63 - fixedCost)
        let trimmed = String(sanitized.prefix(room))
        return "\(prefix)_\(trimmed)\(hash)_\(suffix)"
    }

    /// `noAccess` is the absence of membership, so it has no group of its own.
    static func levelSuffix(_ level: AccessLevel) -> String? {
        switch level {
        case .noAccess:  return nil
        case .readOnly:  return "ro"
        case .readWrite: return "rw"
        case .owner:     return "owner"
        }
    }

    /// All group roles this app manages for a database.
    public static func allGroupRoles(database: String) -> [(level: AccessLevel, role: String)] {
        AccessLevel.allCases.compactMap { level in
            groupRole(database: database, level: level).map { (level, $0) }
        }
    }

    static func sanitize(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            if character.isLetter && character.isASCII { return character }
            if character.isNumber && character.isASCII { return character }
            return "_"
        }
        let collapsed = String(mapped)
        return collapsed.isEmpty ? "db" : collapsed
    }

    /// Short, stable, non-cryptographic hash — only needs to avoid collisions between names
    /// that truncate to the same prefix.
    static func shortHash(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(String(hash, radix: 36).prefix(6))
    }
}
