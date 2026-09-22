import ServiceKit
import SwiftUI

/// Who is connected right now. Refreshes on a timer only while this screen is visible.
struct ConnectionsView: View {
    @Environment(PostgresModel.self) private var model
    @StateObject private var local = ConnectionsState()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.activity.isEmpty {
                EmptyStateView(
                    symbol: "bolt.horizontal",
                    title: "No clients connected",
                    message: "Applications and psql sessions connected to this server will appear here, with what they are running."
                )
            } else {
                Table(model.activity, selection: $local.selection) {
                    TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }
                        .width(60)
                    TableColumn("Database") { Text($0.database ?? "—") }
                    TableColumn("User") { Text($0.user ?? "—") }
                    TableColumn("Application") { Text($0.applicationName?.isEmpty == false ? $0.applicationName! : "—") }
                    TableColumn("From") { Text($0.connectionKind) }
                    TableColumn("State") { session in
                        Text(session.state ?? "—")
                            // Idle-in-transaction is the state that actually causes trouble:
                            // it holds locks open indefinitely.
                            .foregroundStyle(session.state == "idle in transaction" ? Color.orange : Color.primary)
                    }
                    TableColumn("Since") { Text($0.backendStart?.relativeDescription ?? "—") }
                    TableColumn("Query") { session in
                        Text(session.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .help(session.query ?? "")
                    }
                }
                .contextMenu(forSelectionType: ActivityInfo.ID.self) { pids in
                    Button("Cancel Running Query") { act(on: pids, terminate: false) }
                    Button("Disconnect Client", role: .destructive) { act(on: pids, terminate: true) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("Connections")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshActivity() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        // Poll only while this screen is on-screen; the task is cancelled on disappear.
        .task(id: model.showOwnConnections) {
            while !Task.isCancelled {
                await model.refreshActivity()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            local.pendingTerminate.count == 1 ? "Disconnect this client?" : "Disconnect \(local.pendingTerminate.count) clients?",
            isPresented: $local.confirmTerminate,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { performTerminate() }
            Button("Cancel", role: .cancel) { local.pendingTerminate = [] }
        } message: {
            Text("Any transaction the client has open will be rolled back.")
        }
    }

    private var footer: some View {
        @Bindable var model = model
        return HStack {
            Toggle("Show Dev Services's own connections", isOn: $model.showOwnConnections)
                .toggleStyle(.checkbox)
            Spacer()
            Text("\(model.activity.count) connected")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .background(.bar)
    }

    private func act(on pids: Set<ActivityInfo.ID>, terminate: Bool) {
        if terminate {
            local.pendingTerminate = pids
            local.confirmTerminate = true
        } else {
            Task {
                for pid in pids { try? await model.catalog.cancelBackend(pid: pid) }
                await model.refreshActivity()
            }
        }
    }

    private func performTerminate() {
        let pids = local.pendingTerminate
        local.pendingTerminate = []
        Task {
            for pid in pids { try? await model.catalog.terminateBackend(pid: pid) }
            await model.refreshActivity()
        }
    }

    @MainActor
    final class ConnectionsState: ObservableObject {
        @Published var selection = Set<ActivityInfo.ID>()
        @Published var pendingTerminate = Set<ActivityInfo.ID>()
        @Published var confirmTerminate = false
    }
}
