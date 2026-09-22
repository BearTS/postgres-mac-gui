import Foundation

/// The single choke point for putting a user-supplied name into SQL.
///
/// Postgres identifiers cannot be parameter-bound, so they must be quoted. Everything in PGKit
/// that interpolates a database, schema, table, column or role name goes through here.
public enum Identifier {

    public struct InvalidIdentifier: LocalizedError, Sendable {
        public let value: String
        public let reason: String
        public var errorDescription: String? { "Invalid name \"\(value)\": \(reason)" }
    }

    /// Quote an identifier the way `quote_ident()` would, always double-quoting so that
    /// reserved words and mixed case survive.
    public static func quote(_ raw: String) throws -> String {
        try validate(raw)
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Quote a schema-qualified name, e.g. `public.users` -> `"public"."users"`.
    public static func quote(schema: String, name: String) throws -> String {
        try quote(schema) + "." + quote(name)
    }

    /// Quote a string *literal* (for the rare statement that cannot bind a parameter,
    /// such as `ALTER ROLE ... PASSWORD`). Prefers the E'' form is unnecessary here because
    /// `standard_conforming_strings` is on by default since Postgres 9.1.
    public static func literal(_ raw: String) throws -> String {
        guard !raw.contains("\0") else {
            throw InvalidIdentifier(value: raw, reason: "contains a null byte")
        }
        return "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func validate(_ raw: String) throws {
        if raw.isEmpty {
            throw InvalidIdentifier(value: raw, reason: "must not be empty")
        }
        if raw.utf8.count > 63 {
            throw InvalidIdentifier(value: raw, reason: "must be 63 bytes or fewer")
        }
        if raw.contains("\0") {
            throw InvalidIdentifier(value: raw, reason: "must not contain a null byte")
        }
    }

    /// True when a name is safe to type into a new-object form: lowercase, no quoting surprises.
    public static func isSimple(_ raw: String) -> Bool {
        guard let first = raw.first, first.isLetter || first == "_" else { return false }
        return raw.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "_" }
            && raw.utf8.count <= 63
    }
}
