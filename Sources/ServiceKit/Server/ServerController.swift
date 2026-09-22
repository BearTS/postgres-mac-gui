import Foundation

/// Starts, stops and initialises one Postgres cluster.
///
/// Start/stop go through `pg_ctl` by default because it is immediate and reports real errors.
/// When `brew services` has the same formula registered, the caller is expected to route through
/// ``brewServicesStart``/``brewServicesStop`` instead so the two do not fight — see ``ownership``.
public struct ServerController: Sendable {

    public let installation: PostgresInstallation
    public let dataDirectory: String
    public let brewPrefix: String

    public init(installation: PostgresInstallation, dataDirectory: String? = nil, brewPrefix: String = "/opt/homebrew") {
        self.installation = installation
        self.dataDirectory = dataDirectory ?? installation.defaultDataDirectory
        self.brewPrefix = brewPrefix
    }

    // MARK: Paths

    /// Where `pg_ctl start` is told to write the server log.
    public var logFilePath: String { dataDirectory + "/server.log" }

    /// Every place this cluster's log might be, newest-relevant first. Homebrew's own
    /// service writes elsewhere, so the log viewer checks all of these.
    public var candidateLogPaths: [String] {
        var paths = [logFilePath]
        if case .homebrew(let formula) = installation.source {
            paths.append("\(brewPrefix)/var/log/\(formula).log")
        }
        paths.append("\(dataDirectory)/log")
        return paths
    }

    public var configFilePath: String { dataDirectory + "/postgresql.conf" }
    public var autoConfFilePath: String { dataDirectory + "/postgresql.auto.conf" }
    public var hbaFilePath: String { dataDirectory + "/pg_hba.conf" }

    public var clusterExists: Bool {
        FileManager.default.fileExists(atPath: dataDirectory + "/PG_VERSION")
    }

    // MARK: Status

    /// Cheap status check: reads `postmaster.pid` and verifies the process is alive.
    public func status() -> ServerStatus {
        guard clusterExists else { return .noCluster }
        guard let pidFile = PostmasterPID.read(dataDirectory: dataDirectory) else { return .stopped }
        guard pidFile.processIsAlive else { return .stalePidFile }
        return pidFile.isReady
            ? .running(pid: pidFile.pid, port: pidFile.port)
            : .starting(pid: pidFile.pid)
    }

    public func postmaster() -> PostmasterPID? {
        PostmasterPID.read(dataDirectory: dataDirectory)
    }

    /// Confirm the server actually accepts connections. `running` is not the same as `ready`.
    public func isReady() async -> Bool {
        guard let pidFile = postmaster() else { return false }
        var args = ["-p", String(pidFile.port), "-q", "-t", "3"]
        if let socketDir = pidFile.socketDirectory {
            args += ["-h", socketDir]
        }
        let result = try? await ProcessRunner.run(installation.pgIsReady, args)
        return result?.isSuccess ?? false
    }

    /// Human-readable `pg_ctl status` output, for the diagnostics pane.
    public func statusDescription() async -> String {
        let result = try? await ProcessRunner.run(installation.pgCtl, ["status", "-D", dataDirectory])
        guard let result else { return "pg_ctl status could not be run." }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? result.failureMessage : text
    }

    /// Decide who owns the lifecycle of this cluster.
    public func ownership(brew: BrewClient?) async -> ServerOwnership {
        guard let brew, case .homebrew(let formula) = installation.source else { return .app }
        guard let service = await brew.postgresService(formula: formula), service.isRegistered else { return .app }
        return .brewServices(formula: formula)
    }

    // MARK: Commands, exposed so the UI can show exactly what it will run

    public func initdbCommand(username: String = NSUserName()) -> (String, [String]) {
        (installation.initdb, [
            "-D", dataDirectory,
            "--username=\(username)",
            "--encoding=UTF8",
            "--locale=en_US.UTF-8",
        ])
    }

    public func startCommand() -> (String, [String]) {
        (installation.pgCtl, ["-D", dataDirectory, "-l", logFilePath, "-w", "-t", "60", "start"])
    }

    public func stopCommand() -> (String, [String]) {
        (installation.pgCtl, ["-D", dataDirectory, "-m", "fast", "-w", "-t", "60", "stop"])
    }

    public func restartCommand() -> (String, [String]) {
        (installation.pgCtl, ["-D", dataDirectory, "-l", logFilePath, "-m", "fast", "-w", "-t", "60", "restart"])
    }

    public func reloadCommand() -> (String, [String]) {
        (installation.pgCtl, ["-D", dataDirectory, "reload"])
    }

    // MARK: Actions

    /// Create the cluster. Streams initdb output.
    public func initializeCluster(username: String = NSUserName()) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = initdbCommand(username: username)
        try? FileManager.default.createDirectory(
            atPath: (dataDirectory as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        return ProcessRunner.lines(exe, args)
    }

    public func start() -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = startCommand()
        return ProcessRunner.lines(exe, args)
    }

    public func stop() -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = stopCommand()
        return ProcessRunner.lines(exe, args)
    }

    public func restart() -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = restartCommand()
        return ProcessRunner.lines(exe, args)
    }

    public func reload() -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = reloadCommand()
        return ProcessRunner.lines(exe, args)
    }

    /// Remove a pid file left behind by a crash, after confirming the process really is gone.
    public func clearStalePidFile() throws {
        guard case .stalePidFile = status() else { return }
        try FileManager.default.removeItem(atPath: dataDirectory + "/" + PostmasterPID.fileName)
    }

    /// Create the per-user database that bare `psql` expects to exist.
    public func createDefaultDatabase(named name: String = NSUserName()) async throws {
        guard let pidFile = postmaster() else { return }
        var args = ["-p", String(pidFile.port)]
        if let socketDir = pidFile.socketDirectory { args += ["-h", socketDir] }
        args.append(name)
        // Already-exists is not an error worth surfacing.
        _ = try? await ProcessRunner.run(installation.createdb, args)
    }

    /// Last lines of whichever log file exists — what to show when a start fails.
    public func recentLog(lines count: Int = 40) -> String? {
        let fm = FileManager.default
        for path in candidateLogPaths where fm.fileExists(atPath: path) {
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(count).joined(separator: "\n")
        }
        return nil
    }

    /// The log file the viewer should tail.
    public func activeLogPath() -> String? {
        candidateLogPaths.first { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }
}
