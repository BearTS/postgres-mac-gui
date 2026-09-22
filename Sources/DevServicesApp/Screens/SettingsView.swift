import ServiceKit
import SwiftUI

struct SettingsView: View {
    @Environment(PostgresModel.self) private var model
    @StateObject private var local = SettingsState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Port") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Port", text: $local.portText)
                                .frame(width: 100)
                            Button("Change and restart") { changePort() }
                                .disabled(local.portText.isEmpty || local.isWorking)
                        }
                        if let problem = local.portProblem {
                            Text(problem).font(.caption).foregroundStyle(.red)
                        }
                        Text("Every connection string pointing at this server has to change too. The new port is checked for conflicts before anything is written.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Start at login") {
                    VStack(alignment: .leading, spacing: 10) {
                        if case .brewServices(let formula) = model.ownership {
                            Label("Handled by brew services (\(formula))", systemImage: "info.circle")
                                .font(.callout)
                            Text("`brew services` already starts this cluster at login. Turn it off there first if you would rather Dev Services owned it.")
                                .font(.caption).foregroundStyle(.secondary)
                            CommandBlock(command: "brew services stop \(formula)")
                        } else {
                            Toggle("Start Postgres when I log in", isOn: $local.launchAtLogin)
                                .onChange(of: local.launchAtLogin) { _, newValue in
                                    toggleLaunchAgent(newValue)
                                }
                            Text("Installs a LaunchAgent at ~/Library/LaunchAgents/\(LaunchAgentManager.label).plist.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Connection strings") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let database = model.selectedDatabase {
                            ForEach(local.connectionStrings, id: \.self) { string in
                                CommandBlock(command: string)
                            }
                            Text("For \(database). Passwords are not included — add the one you set for the user.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Choose a database to see its connection strings.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Paths") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let controller = model.controller {
                            LabeledContent("Data directory", value: controller.dataDirectory).textSelection(.enabled)
                            LabeledContent("Config file", value: controller.configFilePath).textSelection(.enabled)
                            LabeledContent("Log file", value: controller.activeLogPath() ?? controller.logFilePath)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Homebrew prefix", value: model.brewPrefix)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .task {
            local.portText = model.postmaster.map { String($0.port) } ?? "5432"
            local.launchAtLogin = await LaunchAgentManager.isLoaded()
            await refreshConnectionStrings()
        }
        .task(id: model.selectedDatabase) { await refreshConnectionStrings() }
    }

    private func refreshConnectionStrings() async {
        guard let database = model.selectedDatabase, let target = await model.connectionTarget else {
            local.connectionStrings = []
            return
        }
        local.connectionStrings = [
            target.uri(database: database),
            "psql \"\(target.uri(database: database))\"",
        ]
    }

    private func changePort() {
        guard let port = Int(local.portText), let controller = model.controller else { return }
        let current = model.postmaster?.port
        if let problem = ConfEditor.validatePort(port, currentPort: current) {
            local.portProblem = problem.errorDescription
            return
        }
        local.portProblem = nil
        local.isWorking = true

        Task {
            defer { local.isWorking = false }
            if model.status.isRunning {
                // ALTER SYSTEM writes postgresql.auto.conf through the server itself, so there
                // is no config parsing and no chance of mangling a hand-edited file.
                do {
                    try await model.connections.execute(.init(unsafeSQL: "ALTER SYSTEM SET port = \(port);"))
                } catch {
                    model.lastError = QueryService.describe(error)
                    return
                }
                await model.disconnect()
                await model.restart()
            } else {
                do {
                    try ConfEditor(path: controller.configFilePath).set("port", to: String(port))
                    await model.start()
                } catch {
                    model.lastError = error.localizedDescription
                }
            }
        }
    }

    private func toggleLaunchAgent(_ enabled: Bool) {
        guard let installation = model.selectedInstallation, let controller = model.controller else { return }
        let manager = LaunchAgentManager(
            installation: installation,
            dataDirectory: controller.dataDirectory,
            logPath: controller.logFilePath
        )
        Task {
            do {
                if enabled { try await manager.enable() } else { try await manager.disable() }
            } catch {
                model.lastError = error.localizedDescription
                local.launchAtLogin = !enabled
            }
        }
    }

    @MainActor
    final class SettingsState: ObservableObject {
        @Published var portText = "5432"
        @Published var portProblem: String?
        @Published var launchAtLogin = false
        @Published var isWorking = false
        @Published var connectionStrings: [String] = []
    }
}
