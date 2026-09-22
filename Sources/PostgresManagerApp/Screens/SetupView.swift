import PGKit
import SwiftUI

/// Shown when there is no Postgres server, or no data directory yet.
///
/// The exact commands are always visible and copyable — the "Run for me" button is a
/// convenience, not a black box.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = SetupState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if case .notInstalled = model.status {
                    installSection
                } else {
                    clusterSection
                }

                if !local.output.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output").font(.headline)
                        ProcessOutputView(lines: local.output)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Set Up Postgres")
        .task { local.selectedFormula = model.formulae.first { $0.majorVersion == 18 } ?? model.formulae.first }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if case .notInstalled = model.status { return "No Postgres server found" }
        return "Create a data directory"
    }

    private var subtitle: String {
        if case .notInstalled = model.status {
            return "Pick a version and install it with Homebrew. Nothing runs until you say so, and every command is shown first."
        }
        return "PostgreSQL is installed but has no cluster yet. `initdb` creates one — this is where your databases will live."
    }

    // MARK: Install

    @ViewBuilder
    private var installSection: some View {
        if model.brew == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Homebrew is required").font(.headline)
                Text("Postgres Manager installs Postgres through Homebrew. Install Homebrew first, then reopen this app.")
                    .foregroundStyle(.secondary)
                CommandBlock(command: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose a version").font(.headline)

                Picker("PostgreSQL version", selection: $local.selectedFormula) {
                    ForEach(model.formulae) { formula in
                        Text(formula.isInstalled
                             ? "\(formula.displayName) — installed \(formula.installedVersion ?? "")"
                             : formula.displayName)
                        .tag(Optional(formula))
                    }
                }
                .pickerStyle(.radioGroup)

                if let formula = local.selectedFormula, let brew = model.brew {
                    Text("This runs:").font(.subheadline).foregroundStyle(.secondary)
                    CommandBlock(
                        command: brew.installCommand(formula: formula.name),
                        runTitle: local.isRunning ? "Installing…" : "Run for me",
                        run: local.isRunning ? nil : { install(formula: formula) }
                    )
                    Text("Downloads are a few hundred megabytes and can take several minutes. Output appears below as it happens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Already have Postgres elsewhere?").font(.headline)
                Text("Postgres Manager also finds installations from Postgres.app, the EDB installer, or anything on your PATH. If you just installed one, rescan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Rescan for installations") { Task { await model.discover() } }
            }
        }
    }

    // MARK: Cluster

    @ViewBuilder
    private var clusterSection: some View {
        if let controller = model.controller {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Version", value: model.selectedInstallation?.displayName ?? "—")
                LabeledContent("Data directory", value: controller.dataDirectory)
                    .textSelection(.enabled)

                Text("This runs:").font(.subheadline).foregroundStyle(.secondary)
                let (exe, args) = controller.initdbCommand()
                CommandBlock(
                    command: CommandLog.describe(exe, args),
                    runTitle: local.isRunning ? "Working…" : "Create cluster and start",
                    run: local.isRunning ? nil : { createCluster() }
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("You will be the superuser", systemImage: "person.badge.key")
                            .font(.callout.weight(.medium))
                        Text("The cluster is created with **\(NSUserName())** as its superuser, and local socket connections are trusted — so this app and a plain `psql` both connect with no password. You can add a password from Users & Access afterwards.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        }
    }

    // MARK: Actions

    private func install(formula: BrewFormula) {
        local.isRunning = true
        local.output = []
        Task {
            _ = await model.install(formula: formula) { line in local.output.append(line) }
            local.isRunning = false
        }
    }

    private func createCluster() {
        local.isRunning = true
        local.output = []
        Task {
            let created = await model.createCluster { line in local.output.append(line) }
            if created {
                _ = await model.startAndPrepare { line in local.output.append(line) }
            }
            local.isRunning = false
        }
    }

    @MainActor
    final class SetupState: ObservableObject {
        @Published var selectedFormula: BrewFormula?
        @Published var output: [ProcessOutputLine] = []
        @Published var isRunning = false
    }
}
