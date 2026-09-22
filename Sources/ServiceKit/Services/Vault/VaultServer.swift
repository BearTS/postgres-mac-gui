import Foundation

/// How a Vault server should be run.
public enum VaultMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// In-memory, automatically unsealed, with a root token you choose. Everything is lost when
    /// the server stops — which is usually exactly what you want locally.
    case dev
    /// File-backed storage that survives restarts. Needs initialising once, and unsealing on
    /// every start.
    case persistent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dev:        return "Dev (in-memory)"
        case .persistent: return "Persistent (file storage)"
        }
    }

    public var explanation: String {
        switch self {
        case .dev:
            return "Starts unsealed with a root token you choose. Nothing is written to disk, so every restart is a clean slate."
        case .persistent:
            return "Secrets are written to disk and survive restarts. Vault must be initialised once, and unsealed each time it starts."
        }
    }
}

/// Builds the process specification and configuration for running Vault.
public struct VaultServer: Sendable {

    public static let serviceName = "vault"

    public let installation: VaultInstallation
    public let mode: VaultMode
    public let address: String
    public let port: Int
    /// Dev mode only: the root token the server starts with.
    public let devRootToken: String

    public init(
        installation: VaultInstallation,
        mode: VaultMode = .dev,
        address: String = "127.0.0.1",
        port: Int = 8200,
        devRootToken: String = "dev-root-token"
    ) {
        self.installation = installation
        self.mode = mode
        self.address = address
        self.port = port
        self.devRootToken = devRootToken
    }

    public var apiURL: URL {
        URL(string: "http://\(address):\(port)")!
    }

    public var uiURL: URL {
        apiURL.appendingPathComponent("ui")
    }

    /// Where a persistent server keeps its data, and the config file describing it.
    public var dataDirectory: String { AppPaths.dataDirectory + "/vault" }
    public var configPath: String { AppPaths.applicationSupport + "/vault.hcl" }

    public var spec: ServiceProcessSpec {
        switch mode {
        case .dev:
            return ServiceProcessSpec(
                name: Self.serviceName,
                executable: installation.path,
                arguments: [
                    "server", "-dev",
                    "-dev-root-token-id=\(devRootToken)",
                    "-dev-listen-address=\(address):\(port)",
                ],
                environment: ["VAULT_ADDR": apiURL.absoluteString]
            )
        case .persistent:
            return ServiceProcessSpec(
                name: Self.serviceName,
                executable: installation.path,
                arguments: ["server", "-config=\(configPath)"],
                environment: ["VAULT_ADDR": apiURL.absoluteString]
            )
        }
    }

    /// Config for a persistent server: file storage, no TLS (this is a local dev tool), UI on.
    public func configFileContents() -> String {
        """
        # Written by Dev Services. Local development only — TLS is disabled.
        ui = true
        disable_mlock = true

        storage "file" {
          path = "\(dataDirectory)"
        }

        listener "tcp" {
          address     = "\(address):\(port)"
          tls_disable = true
        }

        api_addr = "\(apiURL.absoluteString)"
        """
    }

    public func writeConfigFile() throws {
        AppPaths.ensureDirectories()
        try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
        try configFileContents().write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// The command the UI shows before starting anything.
    public var displayCommand: String { spec.commandLine }

    /// Environment a user would need in their own terminal to talk to this server.
    public func shellEnvironment(token: String?) -> [String] {
        var lines = ["export VAULT_ADDR='\(apiURL.absoluteString)'"]
        if let token, !token.isEmpty {
            lines.append("export VAULT_TOKEN='\(token)'")
        }
        return lines
    }

    /// Wipe a persistent server's storage. Dev mode keeps nothing on disk, so there is nothing
    /// to delete for it.
    public func resetStorage() throws {
        guard mode == .persistent else { return }
        if FileManager.default.fileExists(atPath: dataDirectory) {
            try FileManager.default.removeItem(atPath: dataDirectory)
        }
        try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
    }
}
