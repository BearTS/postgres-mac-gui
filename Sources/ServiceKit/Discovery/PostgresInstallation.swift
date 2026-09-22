import Foundation

/// A Postgres *server* installation found on this machine.
///
/// Note the deliberate distinction from a client-only install: Homebrew's `libpq` keg ships
/// `psql`, `pg_ctl` and `pg_dump` but no `postgres` binary, so it must never be treated as a
/// server. ``InstallationScanner`` enforces that by requiring `bin/postgres` to exist.
public struct PostgresInstallation: Identifiable, Sendable, Hashable, Codable {

    public enum Source: Sendable, Hashable, Codable {
        case homebrew(formula: String)
        case postgresApp
        case path

        public var displayName: String {
            switch self {
            case .homebrew(let formula): return "Homebrew (\(formula))"
            case .postgresApp: return "Postgres.app"
            case .path: return "Found on PATH"
            }
        }
    }

    /// Directory containing `postgres`, `pg_ctl`, `initdb`, `pg_dump`, …
    public let binDir: String
    /// Full version string reported by `pg_ctl --version`, e.g. "18.6".
    public let version: String
    public let source: Source
    /// Conventional data directory for this installation. May not exist yet.
    public let defaultDataDirectory: String

    public var id: String { binDir }

    public init(binDir: String, version: String, source: Source, defaultDataDirectory: String) {
        self.binDir = binDir
        self.version = version
        self.source = source
        self.defaultDataDirectory = defaultDataDirectory
    }

    /// Major version number, e.g. 18 for "18.6".
    public var majorVersion: Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    public var displayName: String { "PostgreSQL \(version)" }

    // MARK: Tool paths — always resolved from this installation, never from PATH.
    // Using the libpq keg's older pg_dump against a newer server fails outright, so every
    // caller must go through these.

    public func tool(_ name: String) -> String { binDir + "/" + name }

    public var pgCtl: String { tool("pg_ctl") }
    public var postgres: String { tool("postgres") }
    public var initdb: String { tool("initdb") }
    public var psql: String { tool("psql") }
    public var pgDump: String { tool("pg_dump") }
    public var pgDumpAll: String { tool("pg_dumpall") }
    public var pgRestore: String { tool("pg_restore") }
    public var pgIsReady: String { tool("pg_isready") }
    public var createdb: String { tool("createdb") }
    public var dropdb: String { tool("dropdb") }

    /// Parse the version out of `pg_ctl --version` output.
    ///
    /// The version is not reliably the last token: Homebrew appends its own suffix, giving
    /// `pg_ctl (PostgreSQL) 18.6 (Homebrew)`, and other builds append their own. So pick the
    /// last token that actually looks like a dotted version number.
    public static func parseVersion(fromVersionOutput output: String) -> String? {
        let tokens = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return tokens.last { token in
            guard let first = token.first, first.isNumber else { return false }
            return token.allSatisfy { $0.isNumber || $0 == "." }
        }
    }
}
