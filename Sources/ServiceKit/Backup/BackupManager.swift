import Foundation

public struct BackupArtifact: Identifiable, Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case custom
        case directory
        case plain

        public var label: String {
            switch self {
            case .custom:    return "Custom (.dump)"
            case .directory: return "Directory (parallel)"
            case .plain:     return "Plain SQL (.sql)"
            }
        }

        public var explanation: String {
            switch self {
            case .custom:    return "Compressed and selectively restorable. The right default."
            case .directory: return "The only format pg_dump can write in parallel. Best for large databases."
            case .plain:     return "Readable SQL you can diff or commit. Restored with psql, not pg_restore."
            }
        }

        public var dumpFlag: String {
            switch self {
            case .custom: return "custom"
            case .directory: return "directory"
            case .plain: return "plain"
            }
        }

        public var fileExtension: String {
            switch self {
            case .custom: return "dump"
            case .directory: return "dumpdir"
            case .plain: return "sql"
            }
        }

        /// Plain SQL archives are restored by psql; pg_restore cannot read them.
        public var restoredByPsql: Bool { self == .plain }
    }

    public let id: UUID
    public let path: String
    public let database: String
    public let format: Format
    public let createdAt: Date
    public let sizeBytes: Int64
    /// Versions recorded so the restore screen can warn before a mismatch bites.
    public let serverVersion: String
    public let clientVersion: String

    public init(
        id: UUID = UUID(), path: String, database: String, format: Format,
        createdAt: Date, sizeBytes: Int64, serverVersion: String, clientVersion: String
    ) {
        self.id = id
        self.path = path
        self.database = database
        self.format = format
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.serverVersion = serverVersion
        self.clientVersion = clientVersion
    }

    public var formattedSize: String { ByteFormat.string(sizeBytes) }
    public var sidecarPath: String { path + ".pgminfo.json" }
}

/// Chooses which installation's `pg_dump` / `pg_restore` to run.
///
/// The rule that matters: the client must be **at least** the server's major version. A 17
/// `pg_dump` aborts outright against an 18 server; the reverse is supported and normal. The
/// libpq keg counts as a client here even though it has no server binary.
public struct DumpToolSelector: Sendable {

    public struct NoCompatibleClient: LocalizedError, Sendable {
        public let serverMajor: Int
        public var errorDescription: String? {
            "No pg_dump on this machine is new enough for a PostgreSQL \(serverMajor) server."
        }
        public var recoverySuggestion: String? {
            "Install matching client tools with: brew install postgresql@\(serverMajor)"
        }
    }

    /// A directory containing pg_dump/pg_restore, and the version of those tools.
    public struct ClientTools: Sendable, Hashable {
        public let binDir: String
        public let version: String
        public var majorVersion: Int { Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0 }
        public var pgDump: String { binDir + "/pg_dump" }
        public var pgDumpAll: String { binDir + "/pg_dumpall" }
        public var pgRestore: String { binDir + "/pg_restore" }
        public var psql: String { binDir + "/psql" }
    }

    public init() {}

    /// Every directory that can dump, including client-only kegs such as libpq.
    public func availableClients(installations: [PostgresInstallation], brewPrefix: String = "/opt/homebrew") async -> [ClientTools] {
        var candidates = installations.map(\.binDir)
        candidates.append("\(brewPrefix)/opt/libpq/bin")

        var results: [ClientTools] = []
        var seen = Set<String>()
        for binDir in candidates where !seen.contains(binDir) {
            seen.insert(binDir)
            guard FileManager.default.isExecutableFile(atPath: binDir + "/pg_dump") else { continue }
            guard let output = try? await ProcessRunner.runChecked(binDir + "/pg_dump", ["--version"]),
                  let version = PostgresInstallation.parseVersion(fromVersionOutput: output)
            else { continue }
            results.append(ClientTools(binDir: binDir, version: version))
        }
        return results
    }

    /// Lowest client that is still >= the server, preferring an exact major match so the
    /// archive stays as portable as possible.
    public func select(for serverMajor: Int, from clients: [ClientTools]) throws -> ClientTools {
        let compatible = clients.filter { $0.majorVersion >= serverMajor }
        guard !compatible.isEmpty else { throw NoCompatibleClient(serverMajor: serverMajor) }
        if let exact = compatible.first(where: { $0.majorVersion == serverMajor }) { return exact }
        return compatible.min { $0.majorVersion < $1.majorVersion }!
    }
}

/// Runs `pg_dump` and `pg_restore`, reporting progress from their `--verbose` output.
public struct BackupManager: Sendable {

    public let tools: DumpToolSelector.ClientTools
    /// Socket directory or host; `--host=/tmp` makes libpq use the socket, matching how the
    /// app itself connects so "it worked in the app but the backup failed" cannot happen.
    public let host: String
    public let port: Int
    public let username: String

    public init(tools: DumpToolSelector.ClientTools, host: String, port: Int, username: String) {
        self.tools = tools
        self.host = host
        self.port = port
        self.username = username
    }

    public static func defaultBackupDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Documents/Postgres Backups"
    }

    public static func suggestedFilename(database: String, format: BackupArtifact.Format, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(database)-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    private var connectionArguments: [String] {
        ["--host=\(host)", "--port=\(port)", "--username=\(username)", "--no-password"]
    }

    // MARK: Dump

    public func dumpCommand(database: String, to path: String, format: BackupArtifact.Format) -> (String, [String]) {
        var args = connectionArguments
        args += ["--dbname=\(database)", "--format=\(format.dumpFlag)", "--file=\(path)", "--verbose"]
        if format == .custom { args.append("--compress=6") }
        if format == .directory { args.append("--jobs=\(min(4, ProcessInfo.processInfo.activeProcessorCount))") }
        return (tools.pgDump, args)
    }

    public func dump(database: String, to path: String, format: BackupArtifact.Format) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let (exe, args) = dumpCommand(database: database, to: path, format: format)
        return ProcessRunner.lines(exe, args, environment: Self.childEnvironment())
    }

    /// Roles and their passwords live outside any single database, so they need pg_dumpall.
    public func dumpGlobals(to path: String) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let args = connectionArguments + ["--globals-only", "--file=\(path)"]
        return ProcessRunner.lines(tools.pgDumpAll, args, environment: Self.childEnvironment())
    }

    // MARK: Restore

    public struct RestorePlan: Sendable, Hashable {
        public var archivePath: String
        public var format: BackupArtifact.Format
        public var targetDatabase: String
        /// Drop and recreate objects instead of restoring into an empty database.
        public var cleanFirst: Bool
        /// All-or-nothing. Mutually exclusive with parallel restore — pg_restore refuses both.
        public var singleTransaction: Bool
        public var parallelJobs: Int
        public var noOwner: Bool

        public init(
            archivePath: String, format: BackupArtifact.Format, targetDatabase: String,
            cleanFirst: Bool = false, singleTransaction: Bool = true, parallelJobs: Int = 1, noOwner: Bool = true
        ) {
            self.archivePath = archivePath
            self.format = format
            self.targetDatabase = targetDatabase
            self.cleanFirst = cleanFirst
            self.singleTransaction = singleTransaction
            self.parallelJobs = parallelJobs
            self.noOwner = noOwner
        }
    }

    public func restoreCommand(_ plan: RestorePlan) -> (String, [String]) {
        if plan.format.restoredByPsql {
            var args = connectionArguments
            args += ["--dbname=\(plan.targetDatabase)", "--file=\(plan.archivePath)", "-v", "ON_ERROR_STOP=1"]
            if plan.singleTransaction { args.append("--single-transaction") }
            return (tools.psql, args)
        }

        var args = connectionArguments
        args += ["--dbname=\(plan.targetDatabase)", "--verbose", "--exit-on-error"]
        if plan.noOwner { args += ["--no-owner", "--no-privileges"] }
        if plan.cleanFirst { args += ["--clean", "--if-exists"] }
        // --single-transaction and --jobs cannot be combined; the caller presents them as a choice.
        if plan.singleTransaction {
            args.append("--single-transaction")
        } else if plan.parallelJobs > 1 {
            args.append("--jobs=\(plan.parallelJobs)")
        }
        args.append(plan.archivePath)
        return (tools.pgRestore, args)
    }

    public func restore(_ plan: RestorePlan) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let (exe, args) = restoreCommand(plan)
        return ProcessRunner.lines(exe, args, environment: Self.childEnvironment())
    }

    /// Number of items in an archive, so restore progress is a real fraction rather than a guess.
    public func archiveItemCount(path: String) async -> Int? {
        guard let result = try? await ProcessRunner.run(tools.pgRestore, ["--list", path]), result.isSuccess else {
            return nil
        }
        return result.stdout.split(separator: "\n").filter { !$0.hasPrefix(";") && !$0.isEmpty }.count
    }

    // MARK: Progress

    /// `pg_dump --verbose` writes one line per object to stderr. Counting the "dumping contents of"
    /// lines against a known relation count gives a real progress fraction.
    /// `LC_ALL=C` in the child environment is what keeps these strings in English.
    public static func dumpProgress(line: String, relationCount: Int, seen: inout Int) -> Double? {
        guard relationCount > 0 else { return nil }
        guard line.contains("dumping contents of table") else { return nil }
        seen += 1
        return min(0.98, Double(seen) / Double(relationCount))
    }

    public static func restoreProgress(line: String, itemCount: Int, seen: inout Int) -> Double? {
        guard itemCount > 0 else { return nil }
        guard line.contains("processing item") || line.contains("creating ") else { return nil }
        seen += 1
        return min(0.98, Double(seen) / Double(itemCount))
    }

    /// Environment for dump/restore children. A password, when one is needed, is passed through
    /// `PGPASSFILE` rather than `PGPASSWORD`, because environment variables are readable by the
    /// same user via `ps -E` on macOS.
    static func childEnvironment(passFile: String? = nil) -> [String: String] {
        var extra: [String: String] = [:]
        if let passFile { extra["PGPASSFILE"] = passFile }
        return ProcessRunner.defaultEnvironment(extra: extra)
    }
}
