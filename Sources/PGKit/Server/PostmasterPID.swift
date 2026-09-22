import Foundation

/// Parsed contents of `$PGDATA/postmaster.pid`.
///
/// Reading this file is how the app polls status cheaply: no process spawn, and it reports the
/// port and socket directory the running server *actually* bound, which can differ from what
/// `postgresql.conf` currently says if the config changed after start.
///
/// Line order, as written by the postmaster:
/// 1. PID, 2. data directory, 3. start time (epoch), 4. port,
/// 5. socket directory, 6. first listen address, 7. shared memory key, 8. status
public struct PostmasterPID: Sendable, Equatable {
    public let pid: Int32
    public let dataDirectory: String
    public let startTime: Date?
    public let port: Int
    public let socketDirectory: String?
    public let listenAddress: String?
    public let status: String?

    public static let fileName = "postmaster.pid"

    /// `ready` means it is accepting connections; `starting up` means not yet.
    public var isReady: Bool { status?.hasPrefix("ready") ?? true }

    public init(
        pid: Int32,
        dataDirectory: String,
        startTime: Date?,
        port: Int,
        socketDirectory: String?,
        listenAddress: String?,
        status: String?
    ) {
        self.pid = pid
        self.dataDirectory = dataDirectory
        self.startTime = startTime
        self.port = port
        self.socketDirectory = socketDirectory
        self.listenAddress = listenAddress
        self.status = status
    }

    public static func read(dataDirectory: String) -> PostmasterPID? {
        let path = dataDirectory + "/" + fileName
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(contents)
    }

    public static func parse(_ contents: String) -> PostmasterPID? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }

        func line(_ index: Int) -> String? {
            guard index < lines.count else { return nil }
            let value = lines[index].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        let epoch = line(2).flatMap(Double.init)
        return PostmasterPID(
            pid: pid,
            dataDirectory: lines[1].trimmingCharacters(in: .whitespaces),
            startTime: epoch.map { Date(timeIntervalSince1970: $0) },
            port: line(3).flatMap(Int.init) ?? 5432,
            socketDirectory: line(4),
            listenAddress: line(5),
            status: line(7)
        )
    }

    /// True when a process with this PID exists. A stale pid file is left behind after a crash.
    public var processIsAlive: Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Path of the Unix domain socket this server is listening on, if any.
    public var socketPath: String? {
        guard let socketDirectory else { return nil }
        return "\(socketDirectory)/.s.PGSQL.\(port)"
    }
}
