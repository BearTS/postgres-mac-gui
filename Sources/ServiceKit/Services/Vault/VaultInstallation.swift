import Foundation

/// A Vault binary found on this machine.
public struct VaultInstallation: Identifiable, Sendable, Hashable {
    public let path: String
    public let version: String

    public var id: String { path }
    public var displayName: String { "Vault \(version)" }

    public init(path: String, version: String) {
        self.path = path
        self.version = version
    }

    public var majorVersion: Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    /// Vault moved out of homebrew-core when its licence changed, so the formula lives in
    /// HashiCorp's own tap. This is the command to show a user who does not have it.
    public static let brewFormula = "hashicorp/tap/vault"
    public static var installCommand: String { "brew install \(brewFormula)" }

    /// `vault version` prints `Vault v2.0.0 (sha), built ...`.
    public static func parseVersion(fromVersionOutput output: String) -> String? {
        guard let token = output.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("v") && ($0.dropFirst().first?.isNumber ?? false) })
        else { return nil }
        return String(token.dropFirst())
    }

    /// Find Vault, preferring Homebrew's location over anything else on PATH.
    public static func discover(brewPrefix: String = "/opt/homebrew") async -> VaultInstallation? {
        var candidates = ["\(brewPrefix)/bin/vault"]
        if let onPath = await ProcessRunner.which("vault") { candidates.append(onPath) }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let output = try? await ProcessRunner.runChecked(candidate, ["version"]),
                  let version = parseVersion(fromVersionOutput: output)
            else { continue }
            return VaultInstallation(path: candidate, version: version)
        }
        return nil
    }
}
