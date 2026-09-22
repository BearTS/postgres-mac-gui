import PGKit
import SwiftUI

/// Contents of the menu bar dropdown.
///
/// Everything here reads state the 3-second `postmaster.pid` poll already gathered, so opening
/// the menu never spawns a process and never blocks.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)

        if case .brewServices(let formula) = model.ownership {
            Text("Managed by brew services (\(formula))")
        }

        Divider()

        if model.status.canStart {
            Button("Start Server") { Task { await model.start() } }
        }
        if model.status.canStop {
            Button("Stop Server") { Task { await model.stop() } }
            Button("Restart Server") { Task { await model.restart() } }
        }
        if case .noCluster = model.status {
            Button("Set Up Postgres…") { openMainWindow() }
        }
        if case .notInstalled = model.status {
            Button("Install Postgres…") { openMainWindow() }
        }
        if case .stalePidFile = model.status {
            Button("Clean Up and Start") {
                Task {
                    try? model.controller?.clearStalePidFile()
                    await model.start()
                }
            }
        }

        Divider()

        if model.isConnected {
            Menu("Databases") {
                ForEach(model.databases) { database in
                    Button("\(database.name) — \(database.formattedSize)") {
                        model.selectedDatabase = database.name
                        openMainWindow()
                    }
                }
            }
            Menu("\(model.activity.count) client\(model.activity.count == 1 ? "" : "s") connected") {
                if model.activity.isEmpty {
                    Text("No clients connected")
                } else {
                    ForEach(model.activity) { session in
                        Text("\(session.database ?? "—") · \(session.user ?? "—") · \(session.applicationName ?? "unknown app")")
                    }
                }
            }
            Divider()
        }

        Button("Open Postgres Manager") { openMainWindow() }
            .keyboardShortcut("o")
        Button("Quit Postgres Manager") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        guard let installation = model.selectedInstallation else {
            return "No Postgres installed"
        }
        switch model.status {
        case .running(_, let port):
            return "PostgreSQL \(installation.majorVersion) — running on :\(port)"
        default:
            return "PostgreSQL \(installation.majorVersion) — \(model.status.shortDescription.lowercased())"
        }
    }

    /// For a single `Window` scene, `openWindow` focuses the existing window when it is already
    /// open and creates it otherwise — so it handles both cases. The activation policy then
    /// follows automatically from the window becoming visible.
    private func openMainWindow() {
        openWindow(id: MainWindowPresenter.windowID)
        MainWindowPresenter.shared.activate()
    }
}
