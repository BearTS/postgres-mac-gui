import Foundation
import PostgresNIO

/// Where and how to reach a server.
///
/// Local clusters are reached over the Unix domain socket by default: a freshly `initdb`'d
/// cluster trusts local socket connections, so the app connects as the current macOS user with
/// no password at all. TCP is the fallback and the path for anything non-local.
public struct ConnectionTarget: Sendable, Hashable {

    public enum Endpoint: Sendable, Hashable {
        case unixSocket(path: String)
        case tcp(host: String, port: Int)
    }

    public let endpoint: Endpoint
    public let username: String
    public let password: String?

    public init(endpoint: Endpoint, username: String, password: String?) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
    }

    /// Build a socket target from what a running postmaster reported about itself.
    public static func socket(directory: String, port: Int, username: String, password: String? = nil) -> ConnectionTarget {
        ConnectionTarget(
            endpoint: .unixSocket(path: "\(directory)/.s.PGSQL.\(port)"),
            username: username,
            password: password
        )
    }

    public static func tcp(host: String = "127.0.0.1", port: Int, username: String, password: String?) -> ConnectionTarget {
        ConnectionTarget(endpoint: .tcp(host: host, port: port), username: username, password: password)
    }

    public var socketPath: String? {
        if case .unixSocket(let path) = endpoint { return path }
        return nil
    }

    public var port: Int? {
        switch endpoint {
        case .tcp(_, let port): return port
        case .unixSocket(let path):
            // /tmp/.s.PGSQL.5432 -> 5432
            return Int(path.split(separator: ".").last.map(String.init) ?? "")
        }
    }

    /// Directory a libpq client tool should be given as `--host` to use the same socket.
    public var libpqHost: String? {
        switch endpoint {
        case .unixSocket(let path): return (path as NSString).deletingLastPathComponent
        case .tcp(let host, _): return host
        }
    }

    public var describesSocket: Bool { socketPath != nil }

    /// True when the socket file is actually present — a much clearer failure than a NIO connect error.
    public var socketExists: Bool {
        guard let socketPath else { return true }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    public func configuration(database: String) -> PostgresClient.Configuration {
        var config: PostgresClient.Configuration
        switch endpoint {
        case .unixSocket(let path):
            config = PostgresClient.Configuration(
                unixSocketPath: path, username: username, password: password, database: database
            )
        case .tcp(let host, let port):
            config = PostgresClient.Configuration(
                host: host, port: port, username: username, password: password, database: database, tls: .disable
            )
        }
        // Lets the Connections screen tell the app's own pool apart from the user's clients.
        config.options.additionalStartupParameters = [("application_name", ConnectionManager.applicationName)]
        config.options.minimumConnections = 0
        // A desktop GUI holding 20 idle backends against a dev cluster would alarm the user
        // when they look at their own Connections screen.
        config.options.maximumConnections = 4
        config.options.connectionIdleTimeout = .seconds(120)
        return config
    }

    /// Connection URI suitable for copying into an app's config.
    public func uri(database: String, role: String? = nil, password: String? = nil, forceTCP: Bool = true) -> String {
        let user = role ?? username
        let secret = password ?? self.password
        let credentials = secret.map { "\(Self.escape(user)):\(Self.escape($0))" } ?? Self.escape(user)
        if forceTCP || !describesSocket {
            let host: String
            let port: Int
            if case .tcp(let h, let p) = endpoint { host = h; port = p } else { host = "localhost"; port = self.port ?? 5432 }
            return "postgresql://\(credentials)@\(host):\(port)/\(Self.escape(database))"
        }
        let directory = libpqHost ?? "/tmp"
        return "postgresql://\(credentials)@/\(Self.escape(database))?host=\(Self.escape(directory))&port=\(port ?? 5432)"
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
