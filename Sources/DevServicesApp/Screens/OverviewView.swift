import ServiceKit
import SwiftUI

struct OverviewView: View {
    @Environment(PostgresModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    StatusPill(status: model.status)
                    Spacer()
                    if let installation = model.selectedInstallation {
                        Text(installation.displayName).foregroundStyle(.secondary)
                    }
                }

                if case .brewServices(let formula) = model.ownership {
                    ownershipBanner(formula: formula)
                }
                if case .stalePidFile = model.status {
                    stalePidBanner
                }
                if let error = model.connectionError {
                    banner(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .red,
                        title: "Connected to the server, but could not query it",
                        message: error
                    )
                }

                GroupBox("Server") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let installation = model.selectedInstallation {
                            LabeledContent("Version", value: installation.version)
                            LabeledContent("Installed via", value: installation.source.displayName)
                            LabeledContent("Binaries", value: installation.binDir).textSelection(.enabled)
                        }
                        if let controller = model.controller {
                            LabeledContent("Data directory", value: controller.dataDirectory).textSelection(.enabled)
                        }
                        if let postmaster = model.postmaster {
                            LabeledContent("Port", value: String(postmaster.port))
                            LabeledContent("Socket", value: postmaster.socketPath ?? "—").textSelection(.enabled)
                            LabeledContent("Process ID", value: String(postmaster.pid))
                            if let start = postmaster.startTime {
                                LabeledContent("Started", value: start.relativeDescription)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if model.installations.count > 1 {
                    GroupBox("Installations") {
                        Picker("Manage", selection: Binding(
                            get: { model.selectedInstallation },
                            set: { newValue in
                                model.selectedInstallation = newValue
                                Task { await model.refreshStatus() }
                            }
                        )) {
                            ForEach(model.installations) { installation in
                                Text("\(installation.displayName) — \(installation.source.displayName)")
                                    .tag(Optional(installation))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .padding(6)
                    }
                }

                if model.isConnected {
                    GroupBox("At a glance") {
                        HStack(spacing: 28) {
                            stat("Databases", String(model.databases.count))
                            stat("Roles", String(model.roles.filter(\.canLogin).count))
                            stat("Clients", String(model.activity.count))
                            stat("Total size", ByteFormat.string(model.databases.reduce(0) { $0 + $1.sizeBytes }))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.medium))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func ownershipBanner(formula: String) -> some View {
        banner(
            symbol: "info.circle.fill",
            tint: .orange,
            title: "This cluster is managed by brew services",
            message: "Start and Stop here route through `brew services` so launchd does not immediately restart the server behind your back. It also starts automatically at login."
        )
    }

    private var stalePidBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            banner(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                title: "A PID file was left behind",
                message: "postmaster.pid exists but its process is gone, which usually means the server crashed or was killed. Removing the file lets it start again."
            )
            Button("Clean up and start") {
                Task {
                    try? model.controller?.clearStalePidFile()
                    await model.start()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func banner(symbol: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3)))
    }
}
