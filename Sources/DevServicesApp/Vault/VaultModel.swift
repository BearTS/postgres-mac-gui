import Foundation
import Observation
import ServiceKit
import SwiftUI

@MainActor
@Observable
final class VaultModel {

    // MARK: Configuration

    var installation: VaultInstallation?
    var mode: VaultMode = .dev
    var port = 8200
    /// Dev mode's root token.
    var devRootToken = "dev-root-token"

    // MARK: State

    var status: SupervisedStatus = .notInstalled
    var health: VaultClient.Health?
    var sealStatus: VaultClient.SealStatus?
    var engines: [VaultClient.SecretEngine] = []
    var token: String?
    var isBusy = false
    var busyMessage = ""
    var lastError: String?
    /// Unseal key and root token from initialising a persistent server. Shown once, then kept
    /// in the Keychain.
    var initResult: VaultClient.InitResult?

    private var pollTask: Task<Void, Never>?
    private let keychain = Keychain()

    var server: VaultServer? {
        installation.map {
            VaultServer(installation: $0, mode: mode, port: port, devRootToken: devRootToken)
        }
    }

    var client: VaultClient? {
        server.map { VaultClient(baseURL: $0.apiURL, token: token) }
    }

    var summary: ServiceSummary {
        ServiceSummary(
            isInstalled: installation != nil,
            isRunning: status.isRunning && health?.sealed == false,
            detail: detailText
        )
    }

    private var detailText: String {
        guard installation != nil else { return "Not installed" }
        switch status {
        case .running:
            if let health, health.sealed { return "Running, sealed" }
            return "Running on :\(port)"
        case .starting:            return "Starting…"
        case .stale:               return "Crashed"
        case .stopped:             return "Stopped"
        case .failed(let message): return message
        case .notInstalled:        return "Not installed"
        }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        installation = await VaultInstallation.discover()
        // A token kept from a previous run means the UI works straight away.
        token = (try? keychain.password(cluster: keychainCluster, role: "token")) ?? nil
        if mode == .dev, token == nil { token = devRootToken }
        startPolling()
    }

    private var keychainCluster: String { "vault-\(port)" }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard let server else {
            status = .notInstalled
            return
        }
        status = ProcessSupervisor.shared.status(server.spec)

        guard status.isAlive, let client else {
            health = nil
            sealStatus = nil
            engines = []
            return
        }
        health = try? await client.health()
        sealStatus = try? await client.sealStatus()

        // Listing engines needs both a token and an unsealed server.
        if health?.sealed == false, token != nil {
            engines = (try? await client.secretEngines()) ?? []
        } else {
            engines = []
        }
    }

    // MARK: Actions

    func start() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Starting Vault"
        defer { isBusy = false; busyMessage = "" }

        do {
            if mode == .persistent { try server.writeConfigFile() }
            let id = CommandLog.shared.begin(kind: .shell, command: server.spec.commandLine)
            try await ProcessSupervisor.shared.start(server.spec)

            let probe = VaultClient(baseURL: server.apiURL, token: token)
            let ready = await ProcessSupervisor.shared.waitUntilReady(server.spec, timeout: .seconds(25)) {
                await probe.isReachable()
            }
            CommandLog.shared.finish(id, exitCode: ready ? 0 : 1)

            if !ready {
                // A failed start explains itself in the log, not in the exit status.
                lastError = "Vault did not start.\n\n"
                    + (ProcessSupervisor.shared.recentLog(server.spec) ?? "")
            } else if mode == .dev {
                // A dev server always comes up with the token we asked for.
                token = devRootToken
                try? keychain.set(password: devRootToken, cluster: keychainCluster, role: "token")
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func stop() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Stopping Vault"
        defer { isBusy = false; busyMessage = "" }
        await ProcessSupervisor.shared.stop(server.spec)
        await refresh()
    }

    func restart() async {
        await stop()
        await start()
    }

    /// Stop the server and delete its storage. Dev mode writes nothing to disk, so for it this
    /// is just a restart with a clean slate.
    func reset() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Resetting Vault"
        defer { isBusy = false; busyMessage = "" }

        await ProcessSupervisor.shared.stop(server.spec)
        do {
            try server.resetStorage()
            try? keychain.delete(cluster: keychainCluster, role: "token")
            try? keychain.delete(cluster: keychainCluster, role: "unseal-key")
            initResult = nil
            token = mode == .dev ? devRootToken : nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// First-time setup for a persistent server: a single key share, kept in the Keychain.
    /// Five shares split between five people is the right answer in production and pure
    /// friction on a laptop.
    func initializePersistent() async {
        guard let client else { return }
        isBusy = true
        busyMessage = "Initialising Vault"
        defer { isBusy = false; busyMessage = "" }

        do {
            let result = try await client.initialize()
            initResult = result
            token = result.rootToken
            try? keychain.set(password: result.rootToken, cluster: keychainCluster, role: "token")
            if let key = result.unsealKeys.first {
                try? keychain.set(password: key, cluster: keychainCluster, role: "unseal-key")
                _ = try? await client.withToken(result.rootToken).unseal(key: key)
            }
        } catch {
            lastError = (error as? VaultClient.VaultAPIError)?.errorDescription ?? error.localizedDescription
        }
        await refresh()
    }

    /// Unseal using the key kept from initialisation.
    func unsealWithStoredKey() async {
        guard let client else { return }
        // `try?` on a throwing function returning String? gives String??, so it needs flattening.
        guard let key = (try? keychain.password(cluster: keychainCluster, role: "unseal-key")) ?? nil else {
            lastError = "No unseal key is stored for this server. Enter one below, or reset the server to start over."
            return
        }
        do {
            _ = try await client.unseal(key: key)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func unseal(key: String) async {
        guard let client else { return }
        do {
            _ = try await client.unseal(key: key)
            try? keychain.set(password: key, cluster: keychainCluster, role: "unseal-key")
        } catch {
            lastError = (error as? VaultClient.VaultAPIError)?.errorDescription ?? error.localizedDescription
        }
        await refresh()
    }

    func setToken(_ newToken: String) {
        token = newToken
        try? keychain.set(password: newToken, cluster: keychainCluster, role: "token")
        Task { await refresh() }
    }

    func clearStalePID() async {
        guard let server else { return }
        await ProcessSupervisor.shared.clearStalePIDFile(server.spec)
        await refresh()
    }

    /// Lines a user would paste into their own terminal to talk to this server.
    var shellEnvironment: [String] {
        server?.shellEnvironment(token: token) ?? []
    }
}
