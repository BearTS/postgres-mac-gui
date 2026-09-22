import PGKit
import SwiftUI

/// Users, and what each of them may do in each database.
///
/// The grid is the whole point: pick a level from a menu, review the SQL, apply. No hand-written
/// GRANTs, but nothing hidden either.
struct UsersAccessView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = AccessState()

    var body: some View {
        VStack(spacing: 0) {
            if model.roles.filter({ $0.canLogin && !$0.isSuperuser }).isEmpty {
                EmptyStateView(
                    symbol: "person.2.badge.key",
                    title: "No users yet",
                    message: "Create a user to give an application its own credentials, then set what it may do in each database.",
                    actionTitle: "Create User",
                    action: { local.showCreateUser = true }
                )
            } else {
                matrix
            }
        }
        .navigationTitle("Users & Access")
        .toolbar {
            ToolbarItem {
                Button { local.showCreateUser = true } label: { Label("New User", systemImage: "person.badge.plus") }
            }
            ToolbarItem {
                Button {
                    Task {
                        await model.refreshRoles()
                        await model.refreshAccessMatrix()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            await model.refreshRoles()
            await model.refreshAccessMatrix()
        }
        .sheet(isPresented: $local.showCreateUser) { createUserSheet }
        .sheet(item: $local.pendingScript) { pending in
            SQLPreviewSheet(script: pending.script) { apply(pending) }
        }
    }

    // MARK: Matrix

    private var matrix: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("User").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(connectableDatabases) { database in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(database.name).font(.caption.weight(.semibold))
                            Text(lockdownLabel(database.name))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().gridCellColumns(connectableDatabases.count + 1)

                ForEach(loginRoles) { role in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.name)
                            if !role.memberOf.isEmpty {
                                Text("in \(role.memberOf.count) group\(role.memberOf.count == 1 ? "" : "s")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: 140, alignment: .leading)

                        ForEach(connectableDatabases) { database in
                            cell(role: role.name, database: database.name)
                        }
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func cell(role: String, database: String) -> some View {
        let access = model.accessMatrix[role]?[database] ?? .level(.noAccess)
        return Menu {
            ForEach(AccessLevel.allCases) { level in
                Button {
                    prepareLevelChange(role: role, database: database, level: level)
                } label: {
                    Label(level.label, systemImage: level.symbolName)
                }
            }
            Divider()
            Button("Disconnect this user's sessions too") {
                prepareLevelChange(role: role, database: database, level: .noAccess, disconnect: true)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: access.level?.symbolName ?? "questionmark.circle")
                Text(access.label)
            }
            .font(.caption)
            .foregroundStyle(tint(for: access))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(helpText(for: access))
    }

    private var footer: some View {
        HStack {
            if let database = model.selectedDatabase, !isManaged(database) {
                Label("«\(database)» is not under managed access yet", systemImage: "info.circle")
                    .font(.callout)
                Button("Enable managed access…") { prepareProvision(database: database) }
            }
            Spacer()
            if let database = model.selectedDatabase, isManaged(database) {
                Button("Lock \(database)…") { prepareLockdown(database: database) }
                    .help("Revokes PUBLIC's implicit CONNECT, without which No Access does nothing.")
            }
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: Create user

    private var createUserSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New User").font(.title3.weight(.semibold))
            Form {
                TextField("Username", text: $local.newUsername)
                SecureField("Password", text: $local.newPassword)
            }
            .formStyle(.grouped)
            Text("The password is sent as a bound value, never spliced into SQL text, and is stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { local.showCreateUser = false }
                Button("Create") { createUser() }
                    .buttonStyle(.borderedProminent)
                    .disabled(local.newUsername.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Actions

    private func prepareLevelChange(role: String, database: String, level: AccessLevel, disconnect: Bool = false) {
        Task {
            guard let context = await makeContext(database: database) else { return }
            do {
                var script = SQLScript(title: "Set \(role) to \(level.label) on \(database)", database: database)
                // Provisioning is idempotent, and running it first means a database that was
                // never set up still ends up with the right group roles.
                script.append(contentsOf: try PrivilegePlanner().provisionScript(context))
                script.append(contentsOf: try PrivilegePlanner().assignScript(
                    role: role, level: level, context: context, disconnectExistingSessions: disconnect
                ))
                local.pendingScript = PendingScript(script: script)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    private func prepareProvision(database: String) {
        Task {
            guard let context = await makeContext(database: database) else { return }
            do {
                local.pendingScript = PendingScript(script: try PrivilegePlanner().provisionScript(context))
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    private func prepareLockdown(database: String) {
        Task {
            guard let context = await makeContext(database: database) else { return }
            do {
                var script = try PrivilegePlanner().lockdownScript(context)
                // Say who is about to lose access, rather than letting the user find out later.
                let affected = (try? await model.catalog.rolesRelyingOnPublic(database: database)) ?? []
                if !affected.isEmpty {
                    script.statements.insert(
                        SQLStatement(
                            "-- Roles that can connect today: \(affected.joined(separator: ", "))",
                            because: "After locking, only roles you grant a level will be able to connect.",
                            destructive: false
                        ),
                        at: 0
                    )
                }
                local.pendingScript = PendingScript(script: script)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    private func makeContext(database: String) async -> PrivilegePlanner.Context? {
        let schemas = (try? await model.catalog.schemas(in: database)) ?? ["public"]
        var owners: [String] = []
        for schema in schemas {
            owners += (try? await model.catalog.objectOwners(in: database, schema: schema)) ?? []
        }
        return PrivilegePlanner.Context(
            database: database,
            schemas: schemas,
            objectOwners: owners,
            serverVersionNumber: model.serverVersionNumber
        )
    }

    private func apply(_ pending: PendingScript) {
        Task {
            // Comment-only statements are for the reader, not the server.
            var script = pending.script
            script.statements.removeAll { $0.sql.hasPrefix("--") }
            if await model.apply(script) {
                await model.refreshRoles()
                await model.refreshAccessMatrix()
            }
        }
    }

    private func createUser() {
        let username = local.newUsername
        let password = local.newPassword
        local.showCreateUser = false
        local.newUsername = ""
        local.newPassword = ""
        Task {
            do {
                let script = try PrivilegePlanner().createRoleScript(
                    name: username,
                    password: password.isEmpty ? nil : password,
                    database: ConnectionManager.adminDatabase
                )
                if await model.apply(script), !password.isEmpty {
                    // Keep the password so connection strings can be offered later.
                    try? Keychain().set(
                        password: password,
                        cluster: model.controller?.dataDirectory ?? "default",
                        role: username
                    )
                }
                await model.refreshRoles()
                await model.refreshAccessMatrix()
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Helpers

    private var loginRoles: [RoleInfo] {
        model.roles.filter { $0.canLogin && !$0.isSuperuser }
    }

    private var connectableDatabases: [DatabaseInfo] {
        model.databases.filter { $0.allowsConnections && $0.name != "postgres" }
    }

    /// A database is "managed" once its group roles exist.
    private func isManaged(_ database: String) -> Bool {
        guard let group = GroupRoleNaming.groupRole(database: database, level: .readOnly) else { return false }
        return model.roles.contains { $0.name == group }
    }

    private func lockdownLabel(_ database: String) -> String {
        isManaged(database) ? "managed" : "not managed"
    }

    private func tint(for access: EffectiveAccess) -> Color {
        switch access {
        case .level(.noAccess):  return .secondary
        case .level(.readOnly):  return .blue
        case .level(.readWrite): return .green
        case .level(.owner):     return .purple
        case .custom:            return .orange
        }
    }

    private func helpText(for access: EffectiveAccess) -> String {
        switch access {
        case .level(let level): return level.explanation
        case .custom(let reasons): return reasons.joined(separator: "\n")
        }
    }

    struct PendingScript: Identifiable {
        let id = UUID()
        let script: SQLScript
    }

    @MainActor
    final class AccessState: ObservableObject {
        @Published var showCreateUser = false
        @Published var newUsername = ""
        @Published var newPassword = ""
        @Published var pendingScript: PendingScript?
    }
}
