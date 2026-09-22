import Foundation

/// A Homebrew formula that provides a Postgres server.
public struct BrewFormula: Identifiable, Sendable, Hashable {
    public let name: String          // "postgresql@18"
    public let majorVersion: Int     // 18
    public var installedVersion: String?   // "18.6" when installed

    public var id: String { name }
    public var isInstalled: Bool { installedVersion != nil }
    public var displayName: String { "PostgreSQL \(majorVersion)" }
}

/// State of a formula under `brew services`.
public struct BrewServiceState: Sendable, Hashable {
    public enum Status: String, Sendable {
        case started
        case stopped
        case none
        case error
        case scheduled
        case unknown
    }

    public let name: String
    public let status: Status
    public let user: String?
    public let plistPath: String?

    /// True when brew services owns this formula's lifecycle (it will start at login).
    public var isRegistered: Bool {
        status == .started || status == .scheduled || status == .error
    }
}

/// Thin wrapper over the `brew` CLI. All calls are async and stream-capable.
public struct BrewClient: Sendable {

    public struct NotInstalled: LocalizedError, Sendable {
        public var errorDescription: String? {
            "Homebrew was not found. Install it from https://brew.sh, then reopen Dev Services."
        }
    }

    public let brewPath: String

    public init(brewPath: String) {
        self.brewPath = brewPath
    }

    /// Locate `brew`, preferring the Apple Silicon prefix.
    public static func locate() async -> BrewClient? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return BrewClient(brewPath: candidate)
        }
        if let found = await ProcessRunner.which("brew") {
            return BrewClient(brewPath: found)
        }
        return nil
    }

    /// `brew --prefix`, e.g. /opt/homebrew.
    public func prefix() async -> String {
        (try? await ProcessRunner.runChecked(brewPath, ["--prefix"])) ?? "/opt/homebrew"
    }

    /// Major versions of Postgres this app offers to install, newest first.
    public static let supportedMajorVersions = [18, 17, 16, 15, 14]

    /// Which Postgres formulae exist and which are already installed.
    public func postgresFormulae() async -> [BrewFormula] {
        let installed = await installedPostgresVersions()
        return Self.supportedMajorVersions.map { major in
            let name = "postgresql@\(major)"
            return BrewFormula(name: name, majorVersion: major, installedVersion: installed[name])
        }
    }

    /// Map of formula name -> installed version, from `brew list --formula --versions`.
    public func installedPostgresVersions() async -> [String: String] {
        guard let output = try? await ProcessRunner.runChecked(brewPath, ["list", "--formula", "--versions"]) else {
            return [:]
        }
        return Self.parseListVersions(output)
    }

    static func parseListVersions(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let name = parts.first, name.hasPrefix("postgresql@"), parts.count > 1 else { continue }
            result[name] = parts[1]
        }
        return result
    }

    /// `brew services list --json`, parsed. Empty on any failure — brew services is optional.
    public func services() async -> [BrewServiceState] {
        guard let result = try? await ProcessRunner.run(brewPath, ["services", "list", "--json"]),
              result.isSuccess,
              let data = result.stdout.data(using: .utf8)
        else { return [] }
        return Self.parseServices(data)
    }

    static func parseServices(_ data: Data) -> [BrewServiceState] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let rawStatus = entry["status"] as? String ?? "unknown"
            return BrewServiceState(
                name: name,
                status: BrewServiceState.Status(rawValue: rawStatus) ?? .unknown,
                user: entry["user"] as? String,
                plistPath: entry["file"] as? String
            )
        }
    }

    public func postgresService(formula: String) async -> BrewServiceState? {
        await services().first { $0.name == formula }
    }

    // MARK: Commands shown to the user verbatim

    public func installCommand(formula: String) -> String {
        "\(brewPath) install \(formula)"
    }

    /// Stream `brew install <formula>`.
    public func installStream(formula: String) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        ProcessRunner.lines(brewPath, ["install", formula])
    }

    public func servicesStartStream(formula: String) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        ProcessRunner.lines(brewPath, ["services", "start", formula])
    }

    public func servicesStopStream(formula: String) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        ProcessRunner.lines(brewPath, ["services", "stop", formula])
    }
}
