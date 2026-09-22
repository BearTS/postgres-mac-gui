import PGKit
import SwiftUI

struct DatabasesView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = DatabasesState()

    var body: some View {
        @Bindable var model = model

        Group {
            if model.databases.isEmpty {
                EmptyStateView(
                    symbol: "cylinder.split.1x2",
                    title: "No databases yet",
                    message: "Create one to get started.",
                    actionTitle: "Create Database",
                    action: { local.showCreate = true }
                )
            } else {
                Table(model.databases, selection: $local.selection) {
                    TableColumn("Name") { database in
                        HStack {
                            Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                            Text(database.name)
                            if !database.allowsConnections {
                                Text("no connections").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Owner") { Text($0.owner) }
                    TableColumn("Size") { Text($0.formattedSize).monospacedDigit() }
                    TableColumn("Clients") { Text(String($0.connectionCount)).monospacedDigit() }
                    TableColumn("Encoding") { Text($0.encoding) }
                    TableColumn("Connection string") { database in
                        Button("Copy") { copyConnectionString(for: database.name) }
                            .buttonStyle(.borderless)
                    }
                }
                .contextMenu(forSelectionType: DatabaseInfo.ID.self) { names in
                    Button("Browse Tables") {
                        if let name = names.first {
                            model.selectedDatabase = name
                            Task { await model.refreshTables() }
                        }
                    }
                    Button("Copy Connection String") { names.first.map(copyConnectionString) }
                    Divider()
                    Button("Drop Database…", role: .destructive) {
                        local.pendingDrop = names.first
                    }
                }
            }
        }
        .navigationTitle("Databases")
        .toolbar {
            ToolbarItem {
                Button { local.showCreate = true } label: { Label("New Database", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await model.refreshDatabases() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $local.showCreate) { createSheet }
        .confirmationDialog(
            "Drop \(local.pendingDrop ?? "")?",
            isPresented: Binding(get: { local.pendingDrop != nil }, set: { if !$0 { local.pendingDrop = nil } }),
            titleVisibility: .visible
        ) {
            Button("Drop Database", role: .destructive) { drop() }
            Button("Cancel", role: .cancel) { local.pendingDrop = nil }
        } message: {
            Text("This permanently deletes the database and everything in it. Back it up first if you might want it back.")
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Database").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $local.newName)
                Picker("Owner", selection: $local.newOwner) {
                    Text("Default (\(NSUserName()))").tag("")
                    ForEach(model.roles.filter(\.canLogin)) { role in
                        Text(role.name).tag(role.name)
                    }
                }
            }
            .formStyle(.grouped)

            Text("Created from `template0` so nothing added to `template1` leaks in — that is what causes duplicate-object errors during a later restore.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { local.showCreate = false }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(local.newName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        let name = local.newName
        let owner = local.newOwner.isEmpty ? nil : local.newOwner
        local.showCreate = false
        local.newName = ""
        Task {
            do {
                try await model.catalog.createDatabase(named: name, owner: owner)
                await model.refreshDatabases()
            } catch {
                model.lastError = QueryService.describe(error)
            }
        }
    }

    private func drop() {
        guard let name = local.pendingDrop else { return }
        local.pendingDrop = nil
        Task {
            do {
                // Existing sessions block a drop, so close them first.
                try? await model.catalog.terminateConnections(to: name)
                try await model.catalog.dropDatabase(named: name, force: true)
                await model.refreshDatabases()
            } catch {
                model.lastError = QueryService.describe(error)
            }
        }
    }

    private func copyConnectionString(for database: String) {
        Task {
            guard let target = await model.connectionTarget else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.uri(database: database), forType: .string)
        }
    }

    @MainActor
    final class DatabasesState: ObservableObject {
        @Published var selection = Set<DatabaseInfo.ID>()
        @Published var showCreate = false
        @Published var newName = ""
        @Published var newOwner = ""
        @Published var pendingDrop: String?
    }
}
