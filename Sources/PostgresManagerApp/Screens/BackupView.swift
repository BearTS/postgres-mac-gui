import PGKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = BackupState()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let warning = local.toolWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(warning).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("Back up a database") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Database", selection: $model.selectedDatabase) {
                            ForEach(model.databases) { database in
                                Text(database.name).tag(Optional(database.name))
                            }
                        }
                        Picker("Format", selection: $local.format) {
                            ForEach(BackupArtifact.Format.allCases, id: \.self) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        Text(local.format.explanation).font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Text(local.destinationDirectory).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Change…") { chooseDirectory() }
                        }

                        if let (exe, args) = backupCommand() {
                            CommandBlock(command: CommandLog.describe(exe, args))
                        }

                        HStack {
                            Button(local.isRunning ? "Backing up…" : "Back Up Now") { backUp() }
                                .buttonStyle(.borderedProminent)
                                .disabled(local.isRunning || model.selectedDatabase == nil || local.tools == nil)
                            if local.isRunning {
                                ProgressView(value: local.progress).frame(width: 160)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Restore") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(local.restorePath.isEmpty ? "No archive selected" : local.restorePath)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose Archive…") { chooseArchive() }
                        }

                        Picker("Restore into", selection: $local.restoreMode) {
                            Text("A new database").tag(BackupState.RestoreMode.newDatabase)
                            Text("An existing database (replaces its contents)").tag(BackupState.RestoreMode.existing)
                        }
                        .pickerStyle(.radioGroup)

                        switch local.restoreMode {
                        case .newDatabase:
                            TextField("New database name", text: $local.newDatabaseName)
                        case .existing:
                            Picker("Target", selection: $local.restoreTarget) {
                                ForEach(model.databases) { database in
                                    Text(database.name).tag(database.name)
                                }
                            }
                            Text("Everything currently in that database is dropped and replaced.")
                                .font(.caption).foregroundStyle(.orange)
                        }

                        Picker("Failure handling", selection: $local.singleTransaction) {
                            Text("All-or-nothing (single transaction)").tag(true)
                            Text("Parallel, faster — partial state if it fails").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .help("pg_restore cannot combine a single transaction with parallel jobs, so this is a choice between the two.")

                        Button(local.isRunning ? "Restoring…" : "Restore") { restore() }
                            .buttonStyle(.borderedProminent)
                            .disabled(local.isRunning || local.restorePath.isEmpty || local.tools == nil)
                    }
                    .padding(6)
                }

                if !local.output.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output").font(.headline)
                        ProcessOutputView(lines: local.output)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Backups")
        .task { await resolveTools() }
    }

    // MARK: Tools

    /// Pick a pg_dump at least as new as the server. An older one aborts outright.
    private func resolveTools() async {
        guard let installation = model.selectedInstallation else { return }
        let selector = DumpToolSelector()
        let clients = await selector.availableClients(installations: model.installations, brewPrefix: model.brewPrefix)
        do {
            local.tools = try selector.select(for: installation.majorVersion, from: clients)
            local.toolWarning = nil
        } catch let error as DumpToolSelector.NoCompatibleClient {
            local.tools = nil
            local.toolWarning = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } catch {
            local.toolWarning = error.localizedDescription
        }
    }

    private func manager() -> BackupManager? {
        guard let tools = local.tools, let postmaster = model.postmaster else { return nil }
        return BackupManager(
            tools: tools,
            host: postmaster.socketDirectory ?? "/tmp",
            port: postmaster.port,
            username: NSUserName()
        )
    }

    private func backupCommand() -> (String, [String])? {
        guard let manager = manager(), let database = model.selectedDatabase else { return nil }
        let path = local.destinationDirectory + "/" + BackupManager.suggestedFilename(database: database, format: local.format)
        return manager.dumpCommand(database: database, to: path, format: local.format)
    }

    // MARK: Actions

    private func backUp() {
        guard let manager = manager(), let database = model.selectedDatabase else { return }
        let path = local.destinationDirectory + "/" + BackupManager.suggestedFilename(database: database, format: local.format)
        local.isRunning = true
        local.output = []
        local.progress = 0

        Task {
            let relationCount = model.tables.filter { $0.kind == .table || $0.kind == .partitionedTable }.count
            var seen = 0
            let (exe, args) = manager.dumpCommand(database: database, to: path, format: local.format)
            _ = await model.stream(
                manager.dump(database: database, to: path, format: local.format),
                command: CommandLog.describe(exe, args)
            ) { line in
                local.output.append(line)
                if let progress = BackupManager.dumpProgress(line: line.text, relationCount: relationCount, seen: &seen) {
                    local.progress = progress
                }
            }
            local.progress = 1
            local.isRunning = false
        }
    }

    private func restore() {
        guard let manager = manager() else { return }
        local.isRunning = true
        local.output = []

        Task {
            let format = BackupState.format(forPath: local.restorePath)
            var target = local.restoreTarget

            if local.restoreMode == .newDatabase {
                target = local.newDatabaseName
                do {
                    try await model.catalog.createDatabase(named: target, owner: nil)
                } catch {
                    model.lastError = QueryService.describe(error)
                    local.isRunning = false
                    return
                }
            } else {
                // Open sessions block a destructive restore.
                try? await model.catalog.terminateConnections(to: target)
            }

            let plan = BackupManager.RestorePlan(
                archivePath: local.restorePath,
                format: format,
                targetDatabase: target,
                cleanFirst: local.restoreMode == .existing,
                singleTransaction: local.singleTransaction,
                parallelJobs: local.singleTransaction ? 1 : 4
            )
            let (exe, args) = manager.restoreCommand(plan)
            _ = await model.stream(manager.restore(plan), command: CommandLog.describe(exe, args)) { line in
                local.output.append(line)
            }
            await model.refreshDatabases()
            local.isRunning = false
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            local.destinationDirectory = url.path
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // directory-format dumps are folders
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            local.restorePath = url.path
        }
    }

    @MainActor
    final class BackupState: ObservableObject {
        enum RestoreMode { case newDatabase, existing }

        @Published var format: BackupArtifact.Format = .custom
        @Published var destinationDirectory = BackupManager.defaultBackupDirectory()
        @Published var output: [ProcessOutputLine] = []
        @Published var isRunning = false
        @Published var progress: Double = 0
        @Published var tools: DumpToolSelector.ClientTools?
        @Published var toolWarning: String?

        @Published var restorePath = ""
        @Published var restoreMode: RestoreMode = .newDatabase
        @Published var restoreTarget = ""
        @Published var newDatabaseName = ""
        @Published var singleTransaction = true

        static func format(forPath path: String) -> BackupArtifact.Format {
            if path.hasSuffix(".sql") { return .plain }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? .directory : .custom
        }
    }
}
