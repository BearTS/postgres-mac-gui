import Foundation
import Security

/// Stores role passwords in the macOS Keychain.
///
/// Passwords never reach a command line (visible in `ps`), a log, or `~/.pgpass` in the clear.
/// When a CLI tool genuinely needs one, ``PassFile`` writes a 0600 file and the child is pointed
/// at it via `PGPASSFILE` — environment variables are readable by the same user via `ps -E`.
public struct Keychain: Sendable {

    public static let service = "dev.anujp.devservices"

    public struct KeychainError: LocalizedError, Sendable {
        public let status: OSStatus
        public let operation: String
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }

    public init() {}

    /// Account key. Scoping by cluster and port keeps two local clusters from sharing a secret.
    public static func account(cluster: String, role: String) -> String {
        "\(cluster)/\(role)"
    }

    public func set(password: String, cluster: String, role: String) throws {
        let account = Self.account(cluster: cluster, role: role)
        let data = Data(password.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updates: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus, operation: "update")
            }
            return
        }

        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "Dev Services — \(role)"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus, operation: "add")
        }
    }

    public func password(cluster: String, role: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(cluster: cluster, role: role),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status, operation: "read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(cluster: String, role: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(cluster: cluster, role: role),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }
}

/// Writes a temporary libpq password file for child processes that need one.
public struct PassFile: Sendable {

    public static func directory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/DevServices"
    }

    public static func path() -> String { directory() + "/pgpass" }

    /// Write a 0600 pgpass line and return its path. Fields are colon-separated with `:` and `\`
    /// backslash-escaped, per libpq's format.
    @discardableResult
    public static func write(host: String, port: Int, database: String, username: String, password: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directory(), withIntermediateDirectories: true)
        func escape(_ field: String) -> String {
            field.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
        }
        let line = [escape(host), String(port), escape(database), escape(username), escape(password)]
            .joined(separator: ":") + "\n"

        let path = self.path()
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    public static func remove() {
        try? FileManager.default.removeItem(atPath: path())
    }
}
