import Foundation
import Observation
import PGKit
import SwiftUI

/// Root application state. Everything the UI renders hangs off this.
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    // MARK: Environment

    var brew: BrewClient?
    var brewPrefix = "/opt/homebrew"
    var installations: [PostgresInstallation] = []
    var selectedInstallation: PostgresInstallation?
    var formulae: [BrewFormula] = []
    var ownership: ServerOwnership = .app

    var controller: ServerController? {
        selectedInstallation.map { ServerController(installation: $0, brewPrefix: brewPrefix) }
    }

    // MARK: Server state

    var status: ServerStatus = .notInstalled
    var postmaster: PostmasterPID?
    var isBusy = false
    var busyMessage = ""

    // MARK: Connection & data

    let connections = ConnectionManager()
    var isConnected = false
    var connectionError: String?
    var serverVersionNumber = 0

    var databases: [DatabaseInfo] = []
    var roles: [RoleInfo] = []
    var activity: [ActivityInfo] = []
    var showOwnConnections = false

    var selectedDatabase: String?
    var schemas: [String] = []
    var tables: [TableInfo] = []
    var selectedTable: TableInfo?
    var columns: [ColumnInfo] = []
    var indexes: [IndexInfo] = []

    /// role -> database -> level, as read back from the server.
    var accessMatrix: [String: [String: EffectiveAccess]] = [:]

    var lastError: String?

    var catalog: CatalogService { CatalogService(connections: connections) }
    var queries: QueryService { QueryService(connections: connections) }

    private var statusTimer: Task<Void, Never>?

    init() {
        Task { await bootstrap() }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        brew = await BrewClient.locate()
        if let brew { brewPrefix = await brew.prefix() }
        await discover()
        startStatusPolling()
    }

    func discover() async {
        let scanner = InstallationScanner(brewPrefix: brewPrefix)
        installations = await scanner.scan()
        if selectedInstallation == nil || !installations.contains(where: { $0.id == selectedInstallation?.id }) {
            selectedInstallation = installations.first
        }
        if let brew { formulae = await brew.postgresFormulae() }
        await refreshStatus()
    }

    /// Poll `postmaster.pid` rather than spawning `pg_ctl status` — cheap enough for a timer.
    private func startStatusPolling() {
        statusTimer?.cancel()
        statusTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshStatus() async {
        guard let controller else {
            status = installations.isEmpty ? .notInstalled : .noCluster
            return
        }
        let previous = status
        status = controller.status()
        postmaster = controller.postmaster()

        if let brew {
            ownership = await controller.ownership(brew: brew)
        }

        // Connect as soon as the server becomes ready; drop the pools when it goes away.
        if status.isRunning, !isConnected {
            await connect()
        } else if !status.isRunning, isConnected {
            await disconnect()
        }
        if previous.isRunning != status.isRunning, status.isRunning {
            await refreshEverything()
        }
    }

    // MARK: Connection

    /// Connect over the Unix socket as the current macOS user. A cluster created by this app
    /// trusts local socket connections, so this needs no password at all.
    func connect() async {
        guard let postmaster else { return }
        connectionError = nil

        let socketDirectory = postmaster.socketDirectory
            ?? controller.map { ConfEditor(path: $0.configFilePath).socketDirectory() }
            ?? "/tmp"

        var target = ConnectionTarget.socket(
            directory: socketDirectory, port: postmaster.port, username: NSUserName()
        )
        if !target.socketExists {
            // Fall back to loopback if the cluster was configured without a socket directory.
            target = .tcp(port: postmaster.port, username: NSUserName(), password: nil)
        }

        await connections.connect(to: target)
        do {
            serverVersionNumber = try await connections.serverVersionNumber()
            isConnected = true
            await refreshEverything()
        } catch {
            isConnected = false
            connectionError = QueryService.describe(error)
        }
    }

    func disconnect() async {
        await connections.disconnect()
        isConnected = false
        databases = []
        roles = []
        activity = []
        tables = []
        accessMatrix = [:]
    }

    var connectionTarget: ConnectionTarget? {
        get async { await connections.currentTarget() }
    }

    // MARK: Data refresh

    func refreshEverything() async {
        guard isConnected else { return }
        await refreshDatabases()
        await refreshRoles()
        await refreshActivity()
        if selectedDatabase != nil { await refreshTables() }
    }

    func refreshDatabases() async {
        await capture { self.databases = try await self.catalog.databases() }
        if selectedDatabase == nil {
            selectedDatabase = databases.first(where: { $0.name != "postgres" })?.name ?? databases.first?.name
        }
    }

    func refreshRoles() async {
        await capture { self.roles = try await self.catalog.roles() }
    }

    func refreshActivity() async {
        await capture {
            self.activity = try await self.catalog.activity(includeOwnConnections: self.showOwnConnections)
        }
    }

    func refreshTables() async {
        guard let database = selectedDatabase else { return }
        await capture {
            self.schemas = try await self.catalog.schemas(in: database)
            self.tables = try await self.catalog.tables(in: database)
        }
    }

    func refreshTableDetail() async {
        guard let table = selectedTable, let database = selectedDatabase else { return }
        await capture {
            self.columns = try await self.catalog.columns(of: table, in: database)
            self.indexes = try await self.catalog.indexes(of: table, in: database)
        }
    }

    /// Read every role's effective level for every database, so the matrix shows the truth
    /// rather than what the app last wrote.
    func refreshAccessMatrix() async {
        guard isConnected else { return }
        var matrix: [String: [String: EffectiveAccess]] = [:]
        for role in roles where role.canLogin && !role.isSuperuser {
            var perDatabase: [String: EffectiveAccess] = [:]
            for database in databases where database.allowsConnections {
                if let access = try? await catalog.effectiveAccess(role: role.name, database: database.name) {
                    perDatabase[database.name] = access
                }
            }
            matrix[role.name] = perDatabase
        }
        accessMatrix = matrix
    }

    // MARK: Installation

    /// Install a Postgres formula with Homebrew, streaming output to the caller.
    func install(formula: BrewFormula, onLine: @escaping @MainActor (ProcessOutputLine) -> Void) async -> Bool {
        guard let brew else {
            lastError = "Homebrew was not found. Install it from https://brew.sh first."
            return false
        }
        isBusy = true
        busyMessage = "Installing \(formula.name)"
        defer { isBusy = false; busyMessage = "" }

        let succeeded = await stream(
            brew.installStream(formula: formula.name),
            command: brew.installCommand(formula: formula.name),
            onLine: onLine
        )
        await discover()
        return succeeded
    }

    /// Create the data directory.
    ///
    /// `--auth-local=trust` is what lets the app (and plain `psql`) connect over the socket with
    /// no password, while host connections still require a password. A password can be added
    /// afterwards from the Users screen.
    func createCluster(onLine: @escaping @MainActor (ProcessOutputLine) -> Void) async -> Bool {
        guard let controller else { return false }
        isBusy = true
        busyMessage = "Creating cluster"
        defer { isBusy = false; busyMessage = "" }

        let (exe, args) = controller.initdbCommand()
        let succeeded = await stream(
            controller.initializeCluster(),
            command: CommandLog.describe(exe, args),
            onLine: onLine
        )
        await refreshStatus()
        return succeeded
    }

    /// Start the server and create the per-user database plain `psql` expects.
    func startAndPrepare(onLine: @escaping @MainActor (ProcessOutputLine) -> Void) async -> Bool {
        guard let controller else { return false }
        let (exe, args) = controller.startCommand()
        let started = await stream(controller.start(), command: CommandLog.describe(exe, args), onLine: onLine)
        guard started else { return false }
        await refreshStatus()
        try? await controller.createDefaultDatabase()
        await refreshStatus()
        return true
    }

    /// Like `drain`, but also hands each line to a caller that is showing live output.
    @discardableResult
    func stream(
        _ stream: AsyncThrowingStream<ProcessOutputLine, Error>,
        command: String,
        onLine: @escaping @MainActor (ProcessOutputLine) -> Void
    ) async -> Bool {
        let id = CommandLog.shared.begin(kind: .shell, command: command)
        onLine(.stdout("$ " + command))
        do {
            for try await line in stream {
                CommandLog.shared.append(id, line: line)
                onLine(line)
            }
            CommandLog.shared.finish(id, exitCode: 0)
            return true
        } catch {
            CommandLog.shared.finish(id, error: error)
            onLine(.stderr(error.localizedDescription))
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Server actions

    func start() async { await runServerAction("Starting server") { $0.start() } }
    func stop() async { await runServerAction("Stopping server") { $0.stop() } }
    func restart() async { await runServerAction("Restarting server") { $0.restart() } }

    /// Route start/stop through `brew services` when it owns the cluster — launchd would
    /// otherwise undo a `pg_ctl stop` and the button would look broken.
    private func runServerAction(
        _ message: String,
        _ makeStream: (ServerController) -> AsyncThrowingStream<ProcessOutputLine, Error>
    ) async {
        guard let controller else { return }
        isBusy = true
        busyMessage = message
        defer { isBusy = false; busyMessage = "" }

        if case .brewServices(let formula) = ownership, let brew {
            let stream = message.hasPrefix("Stop")
                ? brew.servicesStopStream(formula: formula)
                : brew.servicesStartStream(formula: formula)
            await drain(stream, command: "brew services \(message.hasPrefix("Stop") ? "stop" : "start") \(formula)")
        } else {
            let (exe, args) = message.hasPrefix("Stop") ? controller.stopCommand()
                : message.hasPrefix("Restart") ? controller.restartCommand()
                : controller.startCommand()
            await drain(makeStream(controller), command: CommandLog.describe(exe, args))
        }
        await refreshStatus()
    }

    /// Feed a process stream into the command log, so the user can always see what ran.
    @discardableResult
    func drain(_ stream: AsyncThrowingStream<ProcessOutputLine, Error>, command: String) async -> Bool {
        let id = CommandLog.shared.begin(kind: .shell, command: command)
        do {
            for try await line in stream {
                CommandLog.shared.append(id, line: line)
            }
            CommandLog.shared.finish(id, exitCode: 0)
            return true
        } catch {
            CommandLog.shared.finish(id, error: error)
            lastError = error.localizedDescription
            // A failed start explains itself in the server log, never in pg_ctl's own output.
            if let tail = controller?.recentLog(lines: 15), !tail.isEmpty {
                lastError = (lastError ?? "") + "\n\nServer log:\n" + tail
            }
            return false
        }
    }

    /// Run a SQL script, recording it and surfacing any error.
    @discardableResult
    func apply(_ script: SQLScript) async -> Bool {
        let id = CommandLog.shared.begin(kind: .sql, command: script.rendered)
        do {
            try await connections.executeInTransaction(script.sqlOnly, database: script.database)
            CommandLog.shared.finish(id, exitCode: 0)
            return true
        } catch {
            let message = QueryService.describe(error)
            CommandLog.shared.append(id, line: .stderr(message))
            CommandLog.shared.finish(id, exitCode: 1)
            lastError = message
            return false
        }
    }

    private func capture(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            lastError = QueryService.describe(error)
        }
    }
}

extension ServerStatus {
    /// Menu bar glyph. Filled when running so status is readable at a glance.
    var menuBarSymbol: String {
        switch self {
        case .running:      return "cylinder.split.1x2.fill"
        case .starting:     return "cylinder.split.1x2"
        case .stopped:      return "cylinder.split.1x2"
        case .noCluster,
             .notInstalled: return "exclamationmark.triangle"
        case .stalePidFile,
             .failed:       return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running:                  return .green
        case .starting:                 return .orange
        case .stopped:                  return .secondary
        case .noCluster, .notInstalled: return .orange
        case .stalePidFile, .failed:    return .red
        }
    }
}
