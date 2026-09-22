import Foundation

/// Finds Postgres server installations on this machine.
public struct InstallationScanner: Sendable {

    public let brewPrefix: String

    public init(brewPrefix: String = "/opt/homebrew") {
        self.brewPrefix = brewPrefix
    }

    /// All installations found, best candidate first.
    ///
    /// Homebrew points several symlinks at one keg (`postgresql@18`, `postgresql`, and the
    /// binaries linked into `bin`), so the same installation is found repeatedly. They are
    /// deduplicated by resolved path, and the survivor is the one whose name tells us the most —
    /// a versioned formula knows its data directory, a bare `postgres` on PATH does not.
    public func scan() async -> [PostgresInstallation] {
        var candidates: [PostgresInstallation] = []
        candidates += await scanHomebrew()
        candidates += await scanPostgresApp()
        if let onPath = await scanPath() { candidates.append(onPath) }

        // Deduplicate by the real path the bin directory resolves to.
        var best: [String: PostgresInstallation] = [:]
        for candidate in candidates {
            let key = Self.resolvedPath(candidate.binDir)
            if let existing = best[key], Self.rank(existing) <= Self.rank(candidate) { continue }
            best[key] = candidate
        }

        return best.values.sorted { lhs, rhs in
            let lhsRank = Self.rank(lhs)
            let rhsRank = Self.rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.majorVersion != rhs.majorVersion { return lhs.majorVersion > rhs.majorVersion }
            return lhs.binDir < rhs.binDir
        }
    }

    /// Lower is better. An installation whose data directory already holds a cluster wins
    /// outright — otherwise the app would offer to create one next to a cluster that exists.
    static func rank(_ installation: PostgresInstallation) -> Int {
        var rank = 0
        if !hasCluster(installation.defaultDataDirectory) { rank += 100 }
        switch installation.source {
        case .homebrew(let formula): rank += formula.contains("@") ? 0 : 2
        case .postgresApp:           rank += 1
        case .path:                  rank += 3
        }
        return rank
    }

    static func hasCluster(_ dataDirectory: String) -> Bool {
        FileManager.default.fileExists(atPath: dataDirectory + "/PG_VERSION")
    }

    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Sources

    /// Homebrew keeps versioned Postgres keg-only at `<prefix>/opt/postgresql@NN`.
    func scanHomebrew() async -> [PostgresInstallation] {
        let optDir = brewPrefix + "/opt"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: optDir) else { return [] }

        var results: [PostgresInstallation] = []
        for entry in entries where entry.hasPrefix("postgresql@") {
            let binDir = "\(optDir)/\(entry)/bin"
            guard Self.isServerBinDir(binDir) else { continue }
            guard let version = await Self.version(ofBinDir: binDir) else { continue }
            let major = entry.split(separator: "@").last.map(String.init) ?? ""
            results.append(PostgresInstallation(
                binDir: binDir,
                version: version,
                source: .homebrew(formula: entry),
                defaultDataDirectory: "\(brewPrefix)/var/postgresql@\(major)"
            ))
        }
        // The unversioned `postgresql` formula, if someone installed that instead.
        let plainBin = "\(optDir)/postgresql/bin"
        if Self.isServerBinDir(plainBin), let version = await Self.version(ofBinDir: plainBin) {
            results.append(PostgresInstallation(
                binDir: plainBin,
                version: version,
                source: .homebrew(formula: "postgresql"),
                defaultDataDirectory: "\(brewPrefix)/var/postgres"
            ))
        }
        return results
    }

    func scanPostgresApp() async -> [PostgresInstallation] {
        let versionsDir = "/Applications/Postgres.app/Contents/Versions"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else { return [] }
        var results: [PostgresInstallation] = []
        for entry in entries where entry != "latest" {
            let binDir = "\(versionsDir)/\(entry)/bin"
            guard Self.isServerBinDir(binDir), let version = await Self.version(ofBinDir: binDir) else { continue }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            results.append(PostgresInstallation(
                binDir: binDir,
                version: version,
                source: .postgresApp,
                defaultDataDirectory: "\(home)/Library/Application Support/Postgres/var-\(entry)"
            ))
        }
        return results
    }

    /// A `postgres` binary on PATH that we did not already account for.
    func scanPath() async -> PostgresInstallation? {
        guard let postgresPath = await ProcessRunner.which("postgres") else { return nil }
        let binDir = (postgresPath as NSString).deletingLastPathComponent
        guard Self.isServerBinDir(binDir), let version = await Self.version(ofBinDir: binDir) else { return nil }
        return PostgresInstallation(
            binDir: binDir,
            version: version,
            source: .path,
            defaultDataDirectory: ProcessInfo.processInfo.environment["PGDATA"] ?? "\(brewPrefix)/var/postgres"
        )
    }

    // MARK: Helpers

    /// A real server install has `postgres`, `pg_ctl` and `initdb`.
    /// Homebrew's libpq keg has pg_ctl but *not* postgres — this is what excludes it.
    static func isServerBinDir(_ binDir: String) -> Bool {
        let fm = FileManager.default
        return ["postgres", "pg_ctl", "initdb"].allSatisfy {
            fm.isExecutableFile(atPath: binDir + "/" + $0)
        }
    }

    static func version(ofBinDir binDir: String) async -> String? {
        guard let output = try? await ProcessRunner.runChecked(binDir + "/pg_ctl", ["--version"]) else { return nil }
        return PostgresInstallation.parseVersion(fromVersionOutput: output)
    }
}
