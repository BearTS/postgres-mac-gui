import Foundation
import Testing
@testable import ServiceKit

/// Exercises Vault for real: the supervisor starts a dev server on a spare port, the client
/// talks to it, and the server is stopped again afterwards.
///
/// Disabled unless Vault is installed, so `swift test` stays green without it.
/// Kept outside the suite: a `@Suite` condition cannot reference a static member of the type
/// it is attached to without creating a circular macro reference.
enum VaultTestEnvironment {
    static let candidatePaths = ["/opt/homebrew/bin/vault", "/usr/local/bin/vault"]

    static var isInstalled: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@Suite("Vault live", .enabled(if: VaultTestEnvironment.isInstalled), .serialized)
struct VaultLiveTests {

    /// A port of its own, so a Vault the user is already running is left alone.
    static let testPort = 8319
    static let testToken = "dev-services-test-token"

    func makeServer() async throws -> VaultServer {
        let installation = try #require(await VaultInstallation.discover())
        return VaultServer(
            installation: installation, mode: .dev,
            port: Self.testPort, devRootToken: Self.testToken
        )
    }

    /// Start a dev server, run the body against it, and always stop it again.
    func withServer(_ body: (VaultServer, VaultClient) async throws -> Void) async throws {
        let server = try await makeServer()
        var spec = server.spec
        // Keep the test server's PID and log files away from a real one's.
        spec = ServiceProcessSpec(
            name: "vault-test",
            executable: spec.executable,
            arguments: spec.arguments,
            environment: spec.environment
        )

        await ProcessSupervisor.shared.stop(spec)
        try await ProcessSupervisor.shared.start(spec)

        let client = VaultClient(baseURL: server.apiURL, token: Self.testToken)
        let ready = await ProcessSupervisor.shared.waitUntilReady(spec, timeout: .seconds(25)) {
            await client.isReachable()
        }
        guard ready else {
            let log = ProcessSupervisor.shared.recentLog(spec) ?? "(no log)"
            await ProcessSupervisor.shared.stop(spec)
            Issue.record("Vault did not become ready.\n\(log)")
            return
        }

        do {
            try await body(server, client)
        } catch {
            await ProcessSupervisor.shared.stop(spec)
            throw error
        }
        await ProcessSupervisor.shared.stop(spec)
        #expect(!ProcessSupervisor.shared.status(spec).isAlive)
    }

    @Test("The supervisor starts a dev server that reports healthy and unsealed")
    func startsDevServer() async throws {
        try await withServer { _, client in
            let health = try await client.health()
            #expect(health.initialized)
            #expect(!health.sealed)
            #expect(!health.version.isEmpty)

            let seal = try await client.sealStatus()
            #expect(!seal.sealed)
        }
    }

    @Test("The dev root token is the one we asked for, and it is a root token")
    func devRootTokenWorks() async throws {
        try await withServer { _, client in
            let info = try await client.lookupSelf()
            #expect(info.policies.contains("root"))
        }
    }

    @Test("A wrong token is refused rather than silently returning nothing")
    func wrongTokenIsRefused() async throws {
        try await withServer { server, _ in
            let bad = VaultClient(baseURL: server.apiURL, token: "definitely-not-the-token")
            await #expect(throws: (any Error).self) {
                _ = try await bad.lookupSelf()
            }
        }
    }

    @Test("A dev server comes with a KV version 2 engine mounted at secret/")
    func listsSecretEngines() async throws {
        try await withServer { _, client in
            let engines = try await client.secretEngines()
            let kv = try #require(engines.first { $0.path == "secret/" })
            #expect(kv.type == "kv")
            #expect(kv.kvVersion == 2)
            #expect(kv.isKeyValue)
        }
    }

    @Test("Secrets can be written, listed, read back and deleted")
    func secretRoundTrip() async throws {
        try await withServer { _, client in
            let mount = "secret/"
            try await client.writeSecret(
                mount: mount, path: "myapp/database", kvVersion: 2,
                values: ["username": "app", "password": "s3cret", "port": "5432"]
            )

            let topLevel = try await client.listSecrets(mount: mount, path: "", kvVersion: 2)
            #expect(topLevel.contains("myapp/"))     // a trailing slash means a folder

            let inFolder = try await client.listSecrets(mount: mount, path: "myapp", kvVersion: 2)
            #expect(inFolder.contains("database"))

            let secret = try await client.readSecret(mount: mount, path: "myapp/database", kvVersion: 2)
            #expect(secret.values["username"] == "app")
            #expect(secret.values["password"] == "s3cret")
            #expect(secret.version == 1)

            // Writing again bumps the KV v2 version rather than replacing history.
            try await client.writeSecret(
                mount: mount, path: "myapp/database", kvVersion: 2, values: ["username": "app2"]
            )
            #expect(try await client.readSecret(mount: mount, path: "myapp/database", kvVersion: 2).version == 2)

            try await client.deleteSecret(mount: mount, path: "myapp/database", kvVersion: 2)
            let afterDelete = try await client.listSecrets(mount: mount, path: "myapp", kvVersion: 2)
            #expect(!afterDelete.contains("database"))
        }
    }

    @Test("Listing an empty path returns nothing rather than failing")
    func listingEmptyPathIsNotAnError() async throws {
        try await withServer { _, client in
            let keys = try await client.listSecrets(mount: "secret/", path: "nothing/here", kvVersion: 2)
            #expect(keys.isEmpty)
        }
    }

    @Test("A new KV engine can be enabled and disabled")
    func enableAndDisableEngine() async throws {
        try await withServer { _, client in
            try await client.enableKV(at: "projects")
            let engines = try await client.secretEngines()
            #expect(engines.contains { $0.path == "projects/" && $0.kvVersion == 2 })

            try await client.disableEngine(at: "projects")
            #expect(!(try await client.secretEngines()).contains { $0.path == "projects/" })
        }
    }

    @Test("Vault's own web UI is served, which is what the embedded browser loads")
    func webUIIsServed() async throws {
        try await withServer { server, _ in
            var request = URLRequest(url: server.uiURL.appendingPathComponent("/"))
            request.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }
}

@Suite("Vault configuration")
struct VaultConfigurationTests {

    let installation = VaultInstallation(path: "/opt/homebrew/bin/vault", version: "2.0.0")

    @Test("Versions are parsed from `vault version` output")
    func parsesVersion() {
        #expect(VaultInstallation.parseVersion(fromVersionOutput: "Vault v2.0.0 (cf1ce4d), built 2026-04-13") == "2.0.0")
        #expect(VaultInstallation.parseVersion(fromVersionOutput: "Vault v1.15.2") == "1.15.2")
        #expect(VaultInstallation.parseVersion(fromVersionOutput: "nothing here") == nil)
    }

    @Test("Dev mode passes the chosen root token and listen address")
    func devModeArguments() {
        let server = VaultServer(installation: installation, mode: .dev, port: 8200, devRootToken: "abc")
        let args = server.spec.arguments
        #expect(args.contains("-dev"))
        #expect(args.contains("-dev-root-token-id=abc"))
        #expect(args.contains("-dev-listen-address=127.0.0.1:8200"))
    }

    @Test("Persistent mode runs from a config file instead")
    func persistentModeArguments() {
        let server = VaultServer(installation: installation, mode: .persistent)
        #expect(server.spec.arguments.contains("-config=\(server.configPath)"))
        #expect(!server.spec.arguments.contains("-dev"))
    }

    @Test("The generated config enables the UI and file storage without TLS")
    func configFileContents() {
        let config = VaultServer(installation: installation, mode: .persistent).configFileContents()
        #expect(config.contains("ui = true"))
        #expect(config.contains("storage \"file\""))
        #expect(config.contains("tls_disable = true"))
    }

    @Test("KV v2 splits data and metadata paths; KV v1 does not")
    func kvPaths() {
        #expect(VaultClient.dataPath(mount: "secret/", path: "app/db", kvVersion: 2) == "secret/data/app/db")
        #expect(VaultClient.metadataPath(mount: "secret/", path: "app/db", kvVersion: 2) == "secret/metadata/app/db")
        #expect(VaultClient.dataPath(mount: "kv/", path: "app", kvVersion: 1) == "kv/app")
        #expect(VaultClient.metadataPath(mount: "kv/", path: "app", kvVersion: 1) == "kv/app")
        // Listing the root of a mount must not leave a trailing slash behind.
        #expect(VaultClient.metadataPath(mount: "secret/", path: "", kvVersion: 2) == "secret/metadata")
    }

    @Test("Non-string secret values are rendered readably")
    func stringifyValues() {
        #expect(VaultClient.stringify("plain") == "plain")
        #expect(VaultClient.stringify(true) == "true")
        #expect(VaultClient.stringify(42) == "42")
        #expect(VaultClient.stringify(["a": 1]) == "{\"a\":1}")
    }
}
