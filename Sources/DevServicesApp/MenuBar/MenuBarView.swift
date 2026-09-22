import ServiceKit
import SwiftUI

/// Contents of the menu bar dropdown.
///
/// Every service gets a line showing its state and its own start/stop, so the common case —
/// "turn Postgres on, turn Kafka off" — never needs the window at all. Everything here reads
/// state the background polls already gathered, so opening the menu spawns no processes.
struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(PostgresModel.self) private var postgres
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)

        Divider()

        postgresSection
        Divider()
        vaultSection
        Divider()
        kafkaSection
        Divider()

        Button("Open Dev Services") { openMainWindow() }
            .keyboardShortcut("o")
        Button("Quit Dev Services") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        let running = app.runningCount
        switch running {
        case 0:  return "No services running"
        case 1:  return "1 service running"
        default: return "\(running) services running"
        }
    }

    // MARK: Postgres

    @ViewBuilder
    private var postgresSection: some View {
        Text("PostgreSQL — \(postgres.status.shortDescription)")

        if postgres.status.canStart {
            Button("Start PostgreSQL") { Task { await postgres.start() } }
        }
        if postgres.status.canStop {
            Button("Stop PostgreSQL") { Task { await postgres.stop() } }
            Button("Restart PostgreSQL") { Task { await postgres.restart() } }
        }
        if case .notInstalled = postgres.status {
            Button("Set Up PostgreSQL…") { open(.postgres) }
        }
        if case .noCluster = postgres.status {
            Button("Set Up PostgreSQL…") { open(.postgres) }
        }
        if case .stalePidFile = postgres.status {
            Button("Clean Up and Start") {
                Task {
                    try? postgres.controller?.clearStalePidFile()
                    await postgres.start()
                }
            }
        }

        if postgres.isConnected {
            Menu("Databases") {
                ForEach(postgres.databases) { database in
                    Button("\(database.name) — \(database.formattedSize)") {
                        postgres.selectedDatabase = database.name
                        open(.postgres)
                    }
                }
            }
            Text("\(postgres.activity.count) client\(postgres.activity.count == 1 ? "" : "s") connected")
        }
    }

    // MARK: Vault

    @ViewBuilder
    private var vaultSection: some View {
        let vault = app.vault
        Text("Vault — \(vault.summary.detail)")

        if vault.installation == nil {
            Button("Install Vault…") { open(.vault) }
        } else if vault.status.isAlive {
            Button("Stop Vault") { Task { await vault.stop() } }
            Button("Restart Vault") { Task { await vault.restart() } }
            if vault.health?.sealed == false {
                Button("Open Vault UI") { open(.vault) }
            }
        } else {
            Button("Start Vault") { Task { await vault.start() } }
        }
    }

    // MARK: Kafka

    @ViewBuilder
    private var kafkaSection: some View {
        let kafka = app.kafka
        Text("Kafka — \(kafka.summary.detail)")

        if kafka.installation == nil {
            Button("Install Kafka…") { open(.kafka) }
        } else if kafka.status.isAlive {
            Button("Stop Kafka") { Task { await kafka.stop() } }
            Button("Restart Kafka") { Task { await kafka.restart() } }
            if kafka.brokerReachable {
                Menu("Topics") {
                    if kafka.topics.isEmpty {
                        Text("No topics yet")
                    } else {
                        ForEach(kafka.topics) { topic in
                            Button(topic.name) {
                                kafka.selectedTopic = topic
                                open(.kafka)
                            }
                        }
                    }
                }
            }
        } else {
            Button("Start Kafka") { Task { await kafka.start() } }
        }
    }

    // MARK: Window

    private func open(_ service: ManagedService) {
        app.selectedService = service
        openMainWindow()
    }

    /// For a single `Window` scene, `openWindow` focuses the existing window when it is already
    /// open and creates it otherwise. The Dock icon follows from the window becoming visible.
    private func openMainWindow() {
        openWindow(id: MainWindowPresenter.windowID)
        MainWindowPresenter.shared.activate()
    }
}
