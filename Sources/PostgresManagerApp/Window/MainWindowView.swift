import PGKit
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case databases
    case tables
    case sql
    case access
    case connections
    case backups
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:    return "Overview"
        case .databases:   return "Databases"
        case .tables:      return "Tables"
        case .sql:         return "SQL"
        case .access:      return "Users & Access"
        case .connections: return "Connections"
        case .backups:     return "Backups"
        case .logs:        return "Logs"
        case .settings:    return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview:    return "gauge.with.dots.needle.33percent"
        case .databases:   return "cylinder.split.1x2"
        case .tables:      return "tablecells"
        case .sql:         return "terminal"
        case .access:      return "person.2.badge.key"
        case .connections: return "bolt.horizontal"
        case .backups:     return "externaldrive.badge.timemachine"
        case .logs:        return "doc.text.magnifyingglass"
        case .settings:    return "gearshape"
        }
    }

    /// Sections that need a live connection to show anything useful.
    var requiresConnection: Bool {
        switch self {
        case .overview, .logs, .settings: return false
        default: return true
        }
    }
}

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var navigation = NavigationState()

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $navigation.section) {
                Section {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        // Nothing else is reachable until Postgres exists, so the setup flow takes over.
        if case .notInstalled = model.status {
            SetupView()
        } else if case .noCluster = model.status {
            SetupView()
        } else {
            switch navigation.section {
            case .overview:    OverviewView()
            case .databases:   DatabasesView()
            case .tables:      TableBrowserView()
            case .sql:         SQLEditorView()
            case .access:      UsersAccessView()
            case .connections: ConnectionsView()
            case .backups:     BackupView()
            case .logs:        LogsView()
            case .settings:    SettingsView()
            case .none:        OverviewView()
            }
        }
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            StatusPill(status: model.status)
            if model.isConnected {
                Text("\(model.activity.count) client\(model.activity.count == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.status.canStart {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(model.isBusy)
            }
            if model.status.canStop {
                Button {
                    Task { await model.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(model.isBusy)
                Button {
                    Task { await model.restart() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.busyMessage).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    final class NavigationState: ObservableObject {
        @Published var section: SidebarSection? = .overview
    }
}
