import ServiceKit
import SwiftUI

/// One page in the sidebar, scoped to the service it belongs to.
enum NavigationTarget: Hashable, Identifiable {
    case postgres(PostgresPage)
    case vault(VaultPage)
    case kafka(KafkaPage)

    var id: String {
        switch self {
        case .postgres(let page): return "postgres.\(page.rawValue)"
        case .vault(let page):    return "vault.\(page.rawValue)"
        case .kafka(let page):    return "kafka.\(page.rawValue)"
        }
    }

    var service: ManagedService {
        switch self {
        case .postgres: return .postgres
        case .vault:    return .vault
        case .kafka:    return .kafka
        }
    }

    var title: String {
        switch self {
        case .postgres(let page): return page.title
        case .vault(let page):    return page.title
        case .kafka(let page):    return page.title
        }
    }

    var symbol: String {
        switch self {
        case .postgres(let page): return page.symbol
        case .vault(let page):    return page.symbol
        case .kafka(let page):    return page.symbol
        }
    }
}

enum PostgresPage: String, CaseIterable {
    case overview, databases, tables, sql, access, connections, backups, logs, settings

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
}

enum VaultPage: String, CaseIterable {
    case overview, secrets, logs

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .secrets:  return "Secrets"
        case .logs:     return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .secrets:  return "key.horizontal"
        case .logs:     return "doc.text.magnifyingglass"
        }
    }
}

enum KafkaPage: String, CaseIterable {
    case overview, topics, logs

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .topics:   return "Topics & Messages"
        case .logs:     return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .topics:   return "list.bullet.rectangle"
        case .logs:     return "doc.text.magnifyingglass"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppModel.self) private var app
    @Environment(PostgresModel.self) private var postgres
    @StateObject private var navigation = NavigationState()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { postgres.lastError != nil },
                set: { if !$0 { postgres.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { postgres.lastError = nil }
        } message: {
            Text(postgres.lastError ?? "")
        }
    }

    // MARK: Sidebar

    /// One section per service, each showing its own status so a glance answers "what is up?"
    private var sidebar: some View {
        List(selection: $navigation.target) {
            ForEach(ManagedService.allCases) { service in
                Section {
                    ForEach(pages(for: service), id: \.id) { target in
                        Label(target.title, systemImage: target.symbol)
                            .tag(target)
                    }
                } header: {
                    let summary = app.summary(for: service)
                    HStack(spacing: 6) {
                        Circle().fill(summary.tint).frame(width: 7, height: 7)
                        Text(service.title)
                        Spacer()
                        Text(summary.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
    }

    private func pages(for service: ManagedService) -> [NavigationTarget] {
        switch service {
        case .postgres: return PostgresPage.allCases.map { .postgres($0) }
        case .vault:    return VaultPage.allCases.map { .vault($0) }
        case .kafka:    return KafkaPage.allCases.map { .kafka($0) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch navigation.target ?? .postgres(.overview) {
        case .postgres(let page): postgresDetail(page)
        case .vault(let page):    vaultDetail(page)
        case .kafka(let page):    kafkaDetail(page)
        }
    }

    @ViewBuilder
    private func postgresDetail(_ page: PostgresPage) -> some View {
        // Nothing else is reachable until Postgres exists, so setup takes over the pane.
        switch postgres.status {
        case .notInstalled, .noCluster:
            SetupView()
        default:
            switch page {
            case .overview:    OverviewView()
            case .databases:   DatabasesView()
            case .tables:      TableBrowserView()
            case .sql:         SQLEditorView()
            case .access:      UsersAccessView()
            case .connections: ConnectionsView()
            case .backups:     BackupView()
            case .logs:        LogsView()
            case .settings:    SettingsView()
            }
        }
    }

    @ViewBuilder
    private func vaultDetail(_ page: VaultPage) -> some View {
        switch page {
        case .overview: VaultOverviewView()
        case .secrets:  VaultSecretsView()
        case .logs:     VaultLogsView()
        }
    }

    @ViewBuilder
    private func kafkaDetail(_ page: KafkaPage) -> some View {
        switch page {
        case .overview: KafkaOverviewView()
        case .topics:   KafkaTopicsView()
        case .logs:     KafkaLogsView()
        }
    }

    // MARK: Toolbar

    /// Start/stop always acts on the service whose page is showing, so the buttons never
    /// operate on something the user cannot see.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let service = (navigation.target ?? .postgres(.overview)).service
        ToolbarItemGroup {
            switch service {
            case .postgres:
                if postgres.status.canStart {
                    Button { Task { await postgres.start() } } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(postgres.isBusy)
                }
                if postgres.status.canStop {
                    Button { Task { await postgres.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(postgres.isBusy)
                    Button { Task { await postgres.restart() } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(postgres.isBusy)
                }
                if postgres.isBusy {
                    ProgressView().controlSize(.small)
                    Text(postgres.busyMessage).foregroundStyle(.secondary)
                }
            case .vault:
                serviceControls(
                    isAlive: app.vault.status.isAlive,
                    isBusy: app.vault.isBusy,
                    busyMessage: app.vault.busyMessage,
                    start: { await app.vault.start() },
                    stop: { await app.vault.stop() },
                    restart: { await app.vault.restart() }
                )
            case .kafka:
                serviceControls(
                    isAlive: app.kafka.status.isAlive,
                    isBusy: app.kafka.isBusy,
                    busyMessage: app.kafka.busyMessage,
                    start: { await app.kafka.start() },
                    stop: { await app.kafka.stop() },
                    restart: { await app.kafka.restart() }
                )
            }
        }
    }

    @ViewBuilder
    private func serviceControls(
        isAlive: Bool,
        isBusy: Bool,
        busyMessage: String,
        start: @escaping () async -> Void,
        stop: @escaping () async -> Void,
        restart: @escaping () async -> Void
    ) -> some View {
        if isAlive {
            Button { Task { await stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(isBusy)
            Button { Task { await restart() } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(isBusy)
        } else {
            Button { Task { await start() } } label: { Label("Start", systemImage: "play.fill") }
                .disabled(isBusy)
        }
        if isBusy {
            ProgressView().controlSize(.small)
            Text(busyMessage).foregroundStyle(.secondary)
        }
    }

    @MainActor
    final class NavigationState: ObservableObject {
        @Published var target: NavigationTarget? = .postgres(.overview)
    }
}
