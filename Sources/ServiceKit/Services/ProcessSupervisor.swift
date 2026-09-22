import Foundation

/// Where a supervised service keeps its runtime files.
public enum AppPaths {
    public static let appName = "DevServices"

    public static var applicationSupport: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/\(appName)"
    }

    public static var runDirectory: String { applicationSupport + "/run" }
    public static var logDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Logs/\(appName)"
    }
    public static var dataDirectory: String { applicationSupport + "/data" }

    public static func ensureDirectories() {
        for path in [applicationSupport, runDirectory, logDirectory, dataDirectory] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}

/// How to launch one long-running service process.
///
/// Unlike `pg_ctl`, `vault server` and `kafka-server-start` run in the foreground and never
/// daemonise, so the app has to supervise them itself: spawn, record the PID, redirect output to
/// a log file, and find the process again on the next launch.
public struct ServiceProcessSpec: Sendable, Hashable {
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?

    public init(
        name: String,
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var pidFilePath: String { AppPaths.runDirectory + "/\(name).pid" }
    public var logPath: String { AppPaths.logDirectory + "/\(name).log" }

    public var commandLine: String { CommandLog.describe(executable, arguments) }
}

public enum SupervisedStatus: Sendable, Equatable {
    case notInstalled
    case stopped
    /// Process is alive but has not passed its readiness check yet.
    case starting(pid: Int32)
    case running(pid: Int32)
    /// A PID file exists but the process is gone — it crashed or was killed.
    case stale(pid: Int32)
    case failed(String)

    public var pid: Int32? {
        switch self {
        case .starting(let pid), .running(let pid), .stale(let pid): return pid
        default: return nil
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isAlive: Bool {
        switch self {
        case .running, .starting: return true
        default: return false
        }
    }
}

/// Starts, stops and tracks long-running service processes.
///
/// The child is deliberately *not* killed when the app quits: a running server should outlive
/// the window that started it, the same way `brew services` would. It is found again through its
/// PID file, so a relaunched app picks up a server it started an hour ago.
public actor ProcessSupervisor {

    public static let shared = ProcessSupervisor()

    public struct StartFailure: LocalizedError, Sendable {
        public let service: String
        public let detail: String
        public var errorDescription: String? { "\(service) failed to start: \(detail)" }
    }

    /// Processes this app instance launched. Not the source of truth — the PID file is, so that
    /// a server survives an app restart.
    private var running: [String: Process] = [:]

    public init() {}

    // MARK: Status

    /// Read the PID file and check the process is alive. Cheap enough to poll.
    public nonisolated func status(_ spec: ServiceProcessSpec) -> SupervisedStatus {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else { return .notInstalled }
        guard let pid = Self.readPIDFile(spec.pidFilePath) else { return .stopped }
        return Self.isAlive(pid) ? .running(pid: pid) : .stale(pid: pid)
    }

    public nonisolated static func readPIDFile(_ path: String) -> Int32? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` tests for existence without sending a signal. EPERM means it exists but
    /// belongs to someone else, which still counts as alive.
    public nonisolated static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Lifecycle

    @discardableResult
    public func start(_ spec: ServiceProcessSpec) throws -> Int32 {
        AppPaths.ensureDirectories()

        if let pid = Self.readPIDFile(spec.pidFilePath) {
            if Self.isAlive(pid) { return pid }
            // A PID file from a crashed run would otherwise block every future start.
            try? FileManager.default.removeItem(atPath: spec.pidFilePath)
        }

        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            throw StartFailure(service: spec.name, detail: "\(spec.executable) is not installed.")
        }

        // Truncate the log so a failed start's output is not buried under the last run's.
        FileManager.default.createFile(atPath: spec.logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: spec.logPath) else {
            throw StartFailure(service: spec.name, detail: "Could not open \(spec.logPath) for writing.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = ProcessRunner.defaultEnvironment(extra: spec.environment)
        if let workingDirectory = spec.workingDirectory {
            try? FileManager.default.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true)
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.standardOutput = logHandle
        process.standardError = logHandle
        // No TTY is attached, so anything that prompts would hang forever otherwise.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw StartFailure(service: spec.name, detail: error.localizedDescription)
        }

        let pid = process.processIdentifier
        try? String(pid).write(toFile: spec.pidFilePath, atomically: true, encoding: .utf8)
        running[spec.name] = process

        // Clear the PID file when the process exits on its own, so status does not report a
        // stale PID as a crash the user has to clean up.
        process.terminationHandler = { _ in
            if Self.readPIDFile(spec.pidFilePath) == pid {
                try? FileManager.default.removeItem(atPath: spec.pidFilePath)
            }
            try? logHandle.close()
        }
        return pid
    }

    /// SIGTERM, then SIGKILL if it has not gone within the grace period.
    public func stop(_ spec: ServiceProcessSpec, gracePeriod: Duration = .seconds(10)) async {
        guard let pid = Self.readPIDFile(spec.pidFilePath), Self.isAlive(pid) else {
            try? FileManager.default.removeItem(atPath: spec.pidFilePath)
            running[spec.name] = nil
            return
        }

        kill(pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while ContinuousClock.now < deadline, Self.isAlive(pid) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if Self.isAlive(pid) { kill(pid, SIGKILL) }

        try? FileManager.default.removeItem(atPath: spec.pidFilePath)
        running[spec.name] = nil
    }

    public func restart(_ spec: ServiceProcessSpec) async throws {
        await stop(spec)
        try start(spec)
    }

    /// Remove a PID file left behind by a crash.
    public func clearStalePIDFile(_ spec: ServiceProcessSpec) {
        guard case .stale = status(spec) else { return }
        try? FileManager.default.removeItem(atPath: spec.pidFilePath)
    }

    /// Last lines of the service log — where a failed start actually explains itself.
    public nonisolated func recentLog(_ spec: ServiceProcessSpec, lines count: Int = 40) -> String? {
        guard let contents = try? String(contentsOfFile: spec.logPath, encoding: .utf8) else { return nil }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Poll until `check` passes, so "running" means "actually accepting requests".
    public func waitUntilReady(
        _ spec: ServiceProcessSpec,
        timeout: Duration = .seconds(20),
        check: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await check() { return true }
            guard let pid = Self.readPIDFile(spec.pidFilePath), Self.isAlive(pid) else { return false }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }
}
