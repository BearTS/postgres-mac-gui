import Foundation
import Testing
@testable import PGKit

@Suite("Statement splitter")
struct StatementSplitterTests {

    @Test("Plain statements split on semicolons")
    func plainSplit() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2;")
        #expect(statements == ["SELECT 1;", "SELECT 2;"])
    }

    @Test("A trailing statement without a semicolon is still returned")
    func trailingStatement() {
        #expect(StatementSplitter.split("SELECT 1") == ["SELECT 1"])
    }

    @Test("Semicolons inside string literals do not split")
    func semicolonInLiteral() {
        let statements = StatementSplitter.split("SELECT 'a;b'; SELECT 2;")
        #expect(statements == ["SELECT 'a;b';", "SELECT 2;"])
    }

    @Test("Doubled quotes inside a literal are not the end of it")
    func escapedQuote() {
        #expect(StatementSplitter.split("SELECT 'it''s; fine';") == ["SELECT 'it''s; fine';"])
    }

    @Test("Semicolons inside quoted identifiers do not split")
    func semicolonInIdentifier() {
        #expect(StatementSplitter.split("SELECT \"we;ird\";") == ["SELECT \"we;ird\";"])
    }

    @Test("Dollar-quoted function bodies stay in one statement")
    func dollarQuotedBody() {
        let input = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN; RETURN 1; END; $$ LANGUAGE plpgsql; SELECT 2;"
        let statements = StatementSplitter.split(input)
        #expect(statements.count == 2)
        #expect(statements[0].contains("RETURN 1;"))
        #expect(statements[1] == "SELECT 2;")
    }

    @Test("Tagged dollar quotes stay in one statement")
    func taggedDollarQuote() {
        let statements = StatementSplitter.split("DO $pgm$ BEGIN; END $pgm$; SELECT 1;")
        #expect(statements.count == 2)
    }

    @Test("Semicolons in line comments do not split")
    func lineComment() {
        #expect(StatementSplitter.split("SELECT 1 -- this; is a comment\n;") .count == 1)
    }

    @Test("Semicolons in block comments do not split")
    func blockComment() {
        #expect(StatementSplitter.split("SELECT /* a; b */ 1;") == ["SELECT /* a; b */ 1;"])
    }

    @Test("Blank input yields nothing")
    func blankInput() {
        #expect(StatementSplitter.split("   \n  ").isEmpty)
        #expect(StatementSplitter.split(";").isEmpty)
    }
}

@Suite("Identifier quoting")
struct IdentifierTests {

    @Test("Names are always double quoted so reserved words and case survive")
    func quoting() throws {
        #expect(try Identifier.quote("users") == "\"users\"")
        #expect(try Identifier.quote("Order") == "\"Order\"")
    }

    @Test("An embedded double quote is doubled, defeating injection")
    func injectionAttempt() throws {
        let hostile = "alice\"; DROP DATABASE postgres;--"
        #expect(try Identifier.quote(hostile) == "\"alice\"\"; DROP DATABASE postgres;--\"")
    }

    @Test("Literals double their single quotes")
    func literals() throws {
        #expect(try Identifier.literal("it's") == "'it''s'")
    }

    @Test("Empty, over-long and NUL-bearing names are rejected")
    func rejections() {
        #expect(throws: (any Error).self) { try Identifier.quote("") }
        #expect(throws: (any Error).self) { try Identifier.quote(String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try Identifier.quote("a\0b") }
    }

    @Test("Schema-qualified names quote both halves")
    func qualified() throws {
        #expect(try Identifier.quote(schema: "public", name: "users") == "\"public\".\"users\"")
    }
}

@Suite("postmaster.pid parsing")
struct PostmasterPIDTests {

    let sample = """
    54321
    /opt/homebrew/var/postgresql@18
    1758547200
    5432
    /tmp
    localhost
      5432001         41123840
    ready   

    """

    @Test("Every field is read from the expected line")
    func parsesFullFile() throws {
        let parsed = try #require(PostmasterPID.parse(sample))
        #expect(parsed.pid == 54321)
        #expect(parsed.dataDirectory == "/opt/homebrew/var/postgresql@18")
        #expect(parsed.port == 5432)
        #expect(parsed.socketDirectory == "/tmp")
        #expect(parsed.listenAddress == "localhost")
        #expect(parsed.isReady)
        #expect(parsed.socketPath == "/tmp/.s.PGSQL.5432")
    }

    @Test("A file written mid-startup is still usable")
    func handlesTruncatedFile() throws {
        let parsed = try #require(PostmasterPID.parse("54321\n/var/data\n"))
        #expect(parsed.pid == 54321)
        #expect(parsed.port == 5432)          // default when the line is absent
        #expect(parsed.socketDirectory == nil)
    }

    @Test("A server still starting is not reported as ready")
    func notReadyWhileStarting() throws {
        let starting = sample.replacingOccurrences(of: "ready", with: "starting")
        #expect(try #require(PostmasterPID.parse(starting)).isReady == false)
    }

    @Test("Garbage is rejected rather than guessed at")
    func rejectsGarbage() {
        #expect(PostmasterPID.parse("not a pid\n/var/data") == nil)
        #expect(PostmasterPID.parse("") == nil)
    }
}

@Suite("postgresql.conf editing")
struct ConfEditorTests {

    @Test("An active setting is read, ignoring the commented template line")
    func readsActiveSetting() {
        let conf = """
        #port = 5432
        port = 5433
        max_connections = 100
        """
        #expect(ConfEditor.parseValue(for: "port", in: conf) == "5433")
    }

    @Test("Inline comments are stripped")
    func stripsInlineComment() {
        #expect(ConfEditor.parseValue(for: "port", in: "port = 5433 # changed") == "5433")
    }

    @Test("Quoted values lose their quotes")
    func stripsQuotes() {
        #expect(ConfEditor.parseValue(for: "unix_socket_directories", in: "unix_socket_directories = '/tmp'") == "/tmp")
    }

    @Test("A commented-out setting is not treated as active")
    func ignoresCommented() {
        #expect(ConfEditor.parseValue(for: "port", in: "#port = 5432") == nil)
    }

    @Test("Rewriting replaces the active line and leaves everything else alone")
    func rewriteReplacesActiveLine() {
        let conf = "#port = 5432\nport = 5433\nmax_connections = 100\n"
        let updated = ConfEditor.applying(key: "port", value: "5555", to: conf)
        #expect(updated.contains("port = 5555"))
        #expect(!updated.contains("port = 5433"))
        #expect(updated.contains("#port = 5432"))        // comments preserved
        #expect(updated.contains("max_connections = 100"))
    }

    @Test("A setting with no active line is appended")
    func rewriteAppendsMissingSetting() {
        let updated = ConfEditor.applying(key: "port", value: "5555", to: "#port = 5432\n")
        #expect(updated.contains("port = 5555"))
        #expect(ConfEditor.parseValue(for: "port", in: updated) == "5555")
    }

    @Test("Ports below 1024 and out of range are refused")
    func portValidation() {
        #expect(ConfEditor.validatePort(80, currentPort: 5432) == .privileged)
        #expect(ConfEditor.validatePort(70000, currentPort: 5432) == .outOfRange)
        #expect(ConfEditor.validatePort(5432, currentPort: 5432) == nil)   // no change is always fine
    }
}

@Suite("Homebrew output parsing")
struct BrewParsingTests {

    @Test("Installed Postgres versions are picked out of brew list")
    func parsesListVersions() {
        let output = """
        icu4c 78.1
        postgresql@18 18.6
        postgresql@16 16.10
        readline 8.3.1
        """
        let versions = BrewClient.parseListVersions(output)
        #expect(versions["postgresql@18"] == "18.6")
        #expect(versions["postgresql@16"] == "16.10")
        #expect(versions["readline"] == nil)
    }

    @Test("brew services JSON maps to registration state")
    func parsesServices() throws {
        let json = """
        [{"name":"postgresql@18","status":"started","user":"anuj","file":"/Users/anuj/Library/LaunchAgents/homebrew.mxcl.postgresql@18.plist"},
         {"name":"unbound","status":"none","user":null,"file":null}]
        """
        let services = BrewClient.parseServices(Data(json.utf8))
        #expect(services.count == 2)
        let postgres = try #require(services.first { $0.name == "postgresql@18" })
        #expect(postgres.status == .started)
        #expect(postgres.isRegistered)
        #expect(try #require(services.first { $0.name == "unbound" }).isRegistered == false)
    }
}

@Suite("Installation discovery")
struct InstallationTests {

    @Test("Versions are parsed from pg_ctl --version output")
    func parsesVersion() {
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "pg_ctl (PostgreSQL) 18.6") == "18.6")
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "pg_ctl (PostgreSQL) 16.10\n") == "16.10")
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "nonsense") == nil)
    }

    @Test("A build suffix after the version does not confuse the parser")
    func parsesVersionWithBuildSuffix() {
        // Homebrew appends its own name, which is not the last thing on the line.
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "pg_ctl (PostgreSQL) 18.6 (Homebrew)") == "18.6")
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "pg_dump (PostgreSQL) 17.4 (Postgres.app)") == "17.4")
        #expect(PostgresInstallation.parseVersion(fromVersionOutput: "psql (PostgreSQL) 15.8 (Ubuntu 15.8-1)") == "15.8")
    }

    @Test("Tool paths resolve inside the installation, never from PATH")
    func toolPaths() {
        let installation = PostgresInstallation(
            binDir: "/opt/homebrew/opt/postgresql@18/bin",
            version: "18.6",
            source: .homebrew(formula: "postgresql@18"),
            defaultDataDirectory: "/opt/homebrew/var/postgresql@18"
        )
        #expect(installation.pgDump == "/opt/homebrew/opt/postgresql@18/bin/pg_dump")
        #expect(installation.majorVersion == 18)
    }
}

@Suite("Backup planning")
struct BackupTests {

    let selector = DumpToolSelector()

    func client(_ version: String, _ dir: String = "/bin") -> DumpToolSelector.ClientTools {
        DumpToolSelector.ClientTools(binDir: dir, version: version)
    }

    @Test("A client older than the server is never chosen — pg_dump aborts on that combination")
    func rejectsOlderClient() {
        #expect(throws: DumpToolSelector.NoCompatibleClient.self) {
            try selector.select(for: 18, from: [client("16.10"), client("17.4")])
        }
    }

    @Test("An exact major match is preferred over a newer one")
    func prefersExactMatch() throws {
        let chosen = try selector.select(for: 16, from: [client("18.4"), client("16.10"), client("17.4")])
        #expect(chosen.majorVersion == 16)
    }

    @Test("With no exact match, the lowest sufficient client wins")
    func fallsBackToLowestSufficient() throws {
        let chosen = try selector.select(for: 16, from: [client("18.4"), client("17.4")])
        #expect(chosen.majorVersion == 17)
    }

    @Test("Restore never combines --single-transaction with --jobs, which pg_restore refuses")
    func restoreFlagsAreExclusive() {
        let manager = BackupManager(
            tools: client("18.4"), host: "/tmp", port: 5432, username: "anuj"
        )
        var plan = BackupManager.RestorePlan(
            archivePath: "/tmp/a.dump", format: .custom, targetDatabase: "app",
            singleTransaction: true, parallelJobs: 4
        )
        var args = manager.restoreCommand(plan).1
        #expect(args.contains("--single-transaction"))
        #expect(!args.contains { $0.hasPrefix("--jobs") })

        plan.singleTransaction = false
        args = manager.restoreCommand(plan).1
        #expect(args.contains("--jobs=4"))
        #expect(!args.contains("--single-transaction"))
    }

    @Test("--clean always travels with --if-exists")
    func cleanImpliesIfExists() {
        let manager = BackupManager(tools: client("18.4"), host: "/tmp", port: 5432, username: "anuj")
        let plan = BackupManager.RestorePlan(
            archivePath: "/tmp/a.dump", format: .custom, targetDatabase: "app", cleanFirst: true
        )
        let args = manager.restoreCommand(plan).1
        #expect(args.contains("--clean"))
        #expect(args.contains("--if-exists"))
    }

    @Test("Plain SQL archives are restored with psql, which pg_restore cannot read")
    func plainSQLUsesPsql() {
        let manager = BackupManager(tools: client("18.4"), host: "/tmp", port: 5432, username: "anuj")
        let plan = BackupManager.RestorePlan(archivePath: "/tmp/a.sql", format: .plain, targetDatabase: "app")
        #expect(manager.restoreCommand(plan).0.hasSuffix("psql"))
    }

    @Test("Dumps use the socket directory as --host, matching how the app itself connects")
    func dumpUsesSocketHost() {
        let manager = BackupManager(tools: client("18.4"), host: "/tmp", port: 5432, username: "anuj")
        let args = manager.dumpCommand(database: "app", to: "/tmp/a.dump", format: .custom).1
        #expect(args.contains("--host=/tmp"))
        #expect(args.contains("--no-password"))
        #expect(args.contains("--format=custom"))
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {

    @Test("stdout is captured")
    func capturesStdout() async throws {
        let result = try await ProcessRunner.run("/bin/echo", ["hello"])
        #expect(result.isSuccess)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("stdout and stderr are kept apart")
    func separatesStreams() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"])
        #expect(result.stdout.contains("out"))
        #expect(result.stderr.contains("err"))
        #expect(!result.stdout.contains("err"))
    }

    @Test("A non-zero exit is reported, not thrown away")
    func reportsFailure() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.failureMessage.contains("boom"))
    }

    @Test("Output larger than the pipe buffer does not deadlock")
    func handlesLargeOutput() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "for i in $(seq 1 20000); do echo line$i; done"])
        #expect(result.isSuccess)
        #expect(result.stdout.split(separator: "\n").count == 20000)
    }

    @Test("A final line with no trailing newline is still delivered")
    func deliversPartialFinalLine() async throws {
        let result = try await ProcessRunner.run("/usr/bin/printf", ["no-newline"])
        #expect(result.stdout.contains("no-newline"))
    }

    @Test("runChecked throws on failure with the command in the message")
    func runCheckedThrows() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.runChecked("/bin/sh", ["-c", "exit 1"])
        }
    }

    @Test("Homebrew's bin directory is on the child PATH, which a Finder-launched app lacks")
    func environmentIncludesHomebrew() {
        let env = ProcessRunner.defaultEnvironment()
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["LC_ALL"] == "C")     // keeps tool output parseable
    }
}

@Suite("Installation ranking")
struct InstallationRankingTests {

    func installation(
        binDir: String = "/opt/homebrew/opt/postgresql@18/bin",
        source: PostgresInstallation.Source = .homebrew(formula: "postgresql@18"),
        dataDirectory: String
    ) -> PostgresInstallation {
        PostgresInstallation(binDir: binDir, version: "18.6", source: source, defaultDataDirectory: dataDirectory)
    }

    /// A directory that looks like a real cluster, and one that does not.
    func makeTemporaryCluster(withPGVersion: Bool) throws -> String {
        let path = NSTemporaryDirectory() + "pgm-rank-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if withPGVersion {
            try "18\n".write(toFile: path + "/PG_VERSION", atomically: true, encoding: .utf8)
        }
        return path
    }

    @Test("An installation whose data directory already holds a cluster wins")
    func prefersExistingCluster() throws {
        let withCluster = try makeTemporaryCluster(withPGVersion: true)
        let withoutCluster = try makeTemporaryCluster(withPGVersion: false)
        defer {
            try? FileManager.default.removeItem(atPath: withCluster)
            try? FileManager.default.removeItem(atPath: withoutCluster)
        }
        // Even though the loser has the better-looking source, having a real cluster wins.
        let real = installation(source: .homebrew(formula: "postgresql"), dataDirectory: withCluster)
        let empty = installation(source: .homebrew(formula: "postgresql@18"), dataDirectory: withoutCluster)
        #expect(InstallationScanner.rank(real) < InstallationScanner.rank(empty))
    }

    @Test("Among installations with no cluster, a versioned formula beats a bare PATH hit")
    func prefersVersionedFormula() throws {
        let empty = try makeTemporaryCluster(withPGVersion: false)
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let versioned = installation(source: .homebrew(formula: "postgresql@18"), dataDirectory: empty)
        let unversioned = installation(source: .homebrew(formula: "postgresql"), dataDirectory: empty)
        let onPath = installation(source: .path, dataDirectory: empty)
        #expect(InstallationScanner.rank(versioned) < InstallationScanner.rank(unversioned))
        #expect(InstallationScanner.rank(unversioned) < InstallationScanner.rank(onPath))
    }

    @Test("Symlinked duplicates of one keg resolve to the same path so they can be deduplicated")
    func resolvesSymlinks() throws {
        let target = NSTemporaryDirectory() + "pgm-real-\(UUID().uuidString)"
        let link = NSTemporaryDirectory() + "pgm-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: target)
        }
        #expect(InstallationScanner.resolvedPath(link) == InstallationScanner.resolvedPath(target))
    }
}
