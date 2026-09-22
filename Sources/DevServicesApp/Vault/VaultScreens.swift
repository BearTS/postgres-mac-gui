import ServiceKit
import SwiftUI

// MARK: - Overview

struct VaultOverviewView: View {
    @Environment(VaultModel.self) private var model
    @StateObject private var local = VaultOverviewState()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.installation == nil {
                    notInstalled
                } else {
                    statusCard
                    if model.mode == .persistent { persistentCard }
                    configurationCard
                    connectionCard
                    dangerZone
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Vault")
        .alert(
            "Vault",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(
            "Reset Vault?",
            isPresented: $local.confirmReset,
            titleVisibility: .visible
        ) {
            Button("Stop and erase everything", role: .destructive) { Task { await model.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.mode == .dev
                 ? "Dev mode keeps nothing on disk, so this stops the server and clears the stored token."
                 : "This stops Vault and permanently deletes its storage, including every secret and the unseal key.")
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vault is not installed").font(.largeTitle.weight(.semibold))
            Text("Vault moved out of Homebrew's core formulae when its licence changed, so it comes from HashiCorp's own tap.")
                .foregroundStyle(.secondary)
            CommandBlock(command: VaultInstallation.installCommand)
            Button("Rescan") { Task { await model.bootstrap() } }
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(model.summary.tint).frame(width: 9, height: 9)
                    Text(model.summary.detail).font(.title3.weight(.medium))
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.busyMessage).foregroundStyle(.secondary)
                    }
                }

                if let health = model.health {
                    LabeledContent("Version", value: health.version)
                    LabeledContent("Sealed", value: health.sealed ? "Yes" : "No")
                    if let cluster = health.clusterName {
                        LabeledContent("Cluster", value: cluster)
                    }
                }
                if let pid = model.status.pid {
                    LabeledContent("Process ID", value: String(pid))
                }

                HStack {
                    if model.status.isAlive {
                        Button("Stop") { Task { await model.stop() } }
                        Button("Restart") { Task { await model.restart() } }
                    } else {
                        Button("Start") { Task { await model.start() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if case .stale = model.status {
                        Button("Clean up crashed process") { Task { await model.clearStalePID() } }
                    }
                }
                .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private var persistentCard: some View {
        if let seal = model.sealStatus {
            GroupBox("Seal") {
                VStack(alignment: .leading, spacing: 10) {
                    if !seal.initialized {
                        Text("This storage has not been initialised yet. Initialising creates the root token and a single unseal key, both kept in your Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Initialise Vault") { Task { await model.initializePersistent() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                    } else if seal.sealed {
                        Text("Vault is sealed. It cannot read or write secrets until it is unsealed — \(seal.threshold) of \(seal.shares) key(s) required.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Unseal with stored key") { Task { await model.unsealWithStoredKey() } }
                                .buttonStyle(.borderedProminent)
                            SecureField("Or paste an unseal key", text: $local.unsealKey)
                                .frame(width: 260)
                            Button("Unseal") { Task { await model.unseal(key: local.unsealKey); local.unsealKey = "" } }
                                .disabled(local.unsealKey.isEmpty)
                        }
                    } else {
                        Label("Unsealed", systemImage: "lock.open").foregroundStyle(.green)
                    }

                    if let result = model.initResult {
                        Divider()
                        Text("Save these somewhere safe. They are also in your Keychain, but this is the only time they are shown here.")
                            .font(.caption).foregroundStyle(.orange)
                        CommandBlock(command: "Root token: \(result.rootToken)")
                        ForEach(Array(result.unsealKeys.enumerated()), id: \.offset) { _, key in
                            CommandBlock(command: "Unseal key: \(key)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private var configurationCard: some View {
        @Bindable var model = model
        return GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(VaultMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.status.isAlive)
                Text(model.mode.explanation).font(.caption).foregroundStyle(.secondary)

                HStack {
                    Text("Port")
                    TextField("Port", value: $model.port, format: .number.grouping(.never))
                        .frame(width: 80)
                        .disabled(model.status.isAlive)
                }

                if model.mode == .dev {
                    HStack {
                        Text("Root token")
                        TextField("Root token", text: $model.devRootToken)
                            .frame(width: 260)
                            .disabled(model.status.isAlive)
                    }
                    Text("Dev mode starts unsealed with exactly this token, which is what makes it convenient locally — and why it must never be used for anything real.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.status.isAlive {
                    Text("Stop Vault to change these.").font(.caption).foregroundStyle(.secondary)
                }

                if let server = model.server {
                    Text("This runs:").font(.caption).foregroundStyle(.secondary)
                    CommandBlock(command: server.displayCommand)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var connectionCard: some View {
        GroupBox("Use it from a terminal") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.shellEnvironment, id: \.self) { line in
                    CommandBlock(command: line)
                }
                if model.token == nil {
                    Text("No token yet. Start the server, or paste one in the Secrets tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var dangerZone: some View {
        GroupBox("Reset") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erase this Vault").font(.callout.weight(.medium))
                    Text(model.mode == .dev
                         ? "Stops the server and clears the stored token."
                         : "Stops the server and deletes every secret it holds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset…", role: .destructive) { local.confirmReset = true }
                    .disabled(model.isBusy)
            }
            .padding(6)
        }
    }

    @MainActor
    final class VaultOverviewState: ObservableObject {
        @Published var confirmReset = false
        @Published var unsealKey = ""
    }
}

// MARK: - Secrets (Vault's own web UI)

struct VaultSecretsView: View {
    @Environment(VaultModel.self) private var model
    @StateObject private var local = VaultSecretsState()

    var body: some View {
        Group {
            if let server = model.server, model.status.isAlive, model.health?.sealed == false {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    VaultWebUIView(url: server.uiURL, token: model.token, reloadToken: local.reloadToken)
                }
            } else {
                EmptyStateView(
                    symbol: "lock.shield",
                    title: unavailableTitle,
                    message: unavailableMessage,
                    actionTitle: model.status.isAlive ? nil : "Start Vault",
                    action: model.status.isAlive ? nil : { Task { await model.start() } }
                )
            }
        }
        .navigationTitle("Vault Secrets")
    }

    /// Vault's UI is a full application in its own right, so the only chrome worth adding is a
    /// way to reload it and to get the token out for use elsewhere.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { local.reloadToken += 1 } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            if let token = model.token {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    local.copiedToken = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        local.copiedToken = false
                    }
                } label: {
                    Label(local.copiedToken ? "Token copied" : "Copy token", systemImage: "key")
                }
                .buttonStyle(.borderless)
                .help("If the embedded UI asks you to sign in, choose Token and paste this.")
            }

            Spacer()

            if let server = model.server {
                Button {
                    NSWorkspace.shared.open(server.uiURL)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                Text(server.apiURL.absoluteString)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var unavailableTitle: String {
        if model.installation == nil { return "Vault is not installed" }
        if model.health?.sealed == true { return "Vault is sealed" }
        return "Vault is not running"
    }

    private var unavailableMessage: String {
        if model.installation == nil {
            return "Install it from the Overview tab, then start it to browse secrets here."
        }
        if model.health?.sealed == true {
            return "Unseal Vault from the Overview tab to read and write secrets."
        }
        return "Start Vault to browse, create and delete secrets in its own UI, embedded here."
    }

    @MainActor
    final class VaultSecretsState: ObservableObject {
        @Published var reloadToken = 0
        @Published var copiedToken = false
    }
}

// MARK: - Logs

struct VaultLogsView: View {
    @Environment(VaultModel.self) private var model
    @StateObject private var local = VaultLogsState()

    var body: some View {
        Group {
            if local.lines.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "No Vault output yet",
                    message: "Starting Vault writes its output here."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(local.lines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.isError ? Color.red : line.isWarning ? Color.orange : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: local.lines.count) { _, _ in
                        if let last = local.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Vault Logs")
        .task(id: model.server?.spec.logPath) { await tail() }
    }

    private func tail() async {
        guard let path = model.server?.spec.logPath else { return }
        local.lines = []
        for await line in await local.tailer.tail(path: path) {
            local.lines.append(line)
            if local.lines.count > 4000 { local.lines.removeFirst(1000) }
        }
    }

    @MainActor
    final class VaultLogsState: ObservableObject {
        @Published var lines: [LogTailer.Line] = []
        let tailer = LogTailer()
    }
}
