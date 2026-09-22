import Foundation

/// Reads and rewrites settings in `postgresql.conf`.
///
/// While the server is running the app prefers `ALTER SYSTEM SET`, which writes
/// `postgresql.auto.conf` and needs no file parsing. This type covers the stopped case, and
/// reading values before any connection exists.
public struct ConfEditor: Sendable {

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public struct Setting: Sendable, Equatable {
        public let key: String
        public let value: String
        public let lineIndex: Int
        public let isCommented: Bool
    }

    // MARK: Reading

    public func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Value of a setting, ignoring commented-out lines. Quotes and inline comments are stripped.
    public func value(for key: String) -> String? {
        guard let contents = try? read() else { return nil }
        return Self.parseValue(for: key, in: contents)
    }

    public static func parseValue(for key: String, in contents: String) -> String? {
        var found: String?
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let setting = parseLine(String(rawLine)), setting.key == key, !setting.isCommented else { continue }
            found = setting.value   // last non-commented occurrence wins, as Postgres does
        }
        return found
    }

    /// Parse one line into key/value. Returns nil for blank lines and pure comments.
    static func parseLine(_ line: String) -> (key: String, value: String, isCommented: Bool)? {
        var working = line.trimmingCharacters(in: .whitespaces)
        var isCommented = false
        if working.hasPrefix("#") {
            isCommented = true
            working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let equals = working.firstIndex(of: "=") else { return nil }
        let key = String(working[working.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }

        var value = String(working[working.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        // Strip an inline comment that is not inside quotes.
        if !value.hasPrefix("'") , let hash = value.firstIndex(of: "#") {
            value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("'"), let closing = value.dropFirst().firstIndex(of: "'") {
            value = String(value[value.index(after: value.startIndex)..<closing])
            return (key, value, isCommented)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return (key, value, isCommented)
    }

    /// Socket directory the config asks for. Homebrew's build defaults to /tmp.
    public func socketDirectory() -> String {
        guard let raw = value(for: "unix_socket_directories"), !raw.isEmpty else { return "/tmp" }
        let first = raw.split(separator: ",").first.map(String.init) ?? "/tmp"
        return first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    public func port() -> Int {
        value(for: "port").flatMap(Int.init) ?? 5432
    }

    // MARK: Writing

    /// Set a setting, keeping a timestamped `.bak` of the original.
    /// Only safe while the server is stopped; use `ALTER SYSTEM SET` otherwise.
    public func set(_ key: String, to value: String) throws {
        let contents = try read()
        try backup(contents)
        let updated = Self.applying(key: key, value: value, to: contents)
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func backupPath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(path).\(stamp).bak"
    }

    private func backup(_ contents: String) throws {
        try contents.write(toFile: backupPath(), atomically: true, encoding: .utf8)
    }

    /// Rewrite the last active occurrence of `key`, or append the setting if it has none.
    static func applying(key: String, value: String, to contents: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLine = "\(key) = \(value)"

        if let index = lines.lastIndex(where: { parseLine($0).map { $0.key == key && !$0.isCommented } ?? false }) {
            lines[index] = newLine
            return lines.joined(separator: "\n")
        }
        // No active setting: comment out any commented template line and append ours.
        if !lines.isEmpty, lines[lines.count - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines[lines.count - 1] = newLine
            lines.append("")
        } else {
            lines.append(newLine)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Port validation

    public enum PortProblem: LocalizedError, Sendable, Equatable {
        case outOfRange
        case privileged
        case inUse

        public var errorDescription: String? {
            switch self {
            case .outOfRange: return "Port must be between 1024 and 65535."
            case .privileged: return "Ports below 1024 need root privileges."
            case .inUse:      return "That port is already in use by another process."
            }
        }
    }

    /// Check a port is usable before committing a config change.
    public static func validatePort(_ port: Int, currentPort: Int?) -> PortProblem? {
        guard port > 0, port <= 65535 else { return .outOfRange }
        guard port >= 1024 else { return .privileged }
        if port == currentPort { return nil }
        return isPortFree(port) ? nil : .inUse
    }

    /// Attempt to bind the port on loopback; if we can, nothing else holds it.
    static func isPortFree(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return true }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
