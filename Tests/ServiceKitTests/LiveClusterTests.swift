import Foundation
import Testing
@testable import ServiceKit

/// Integration tests against a real Postgres cluster.
///
/// Disabled unless `PGM_TEST_SOCKET` points at a server's socket directory, so `swift test`
/// stays green on a machine with no Postgres:
///
///     PGM_TEST_SOCKET=/tmp PGM_TEST_PORT=5432 Scripts/test.sh
///
@Suite(
    "Live cluster",
    .enabled(if: ProcessInfo.processInfo.environment["PGM_TEST_SOCKET"] != nil),
    .serialized
)
struct LiveClusterTests {

    static var socketDirectory: String { ProcessInfo.processInfo.environment["PGM_TEST_SOCKET"] ?? "/tmp" }
    static var port: Int { Int(ProcessInfo.processInfo.environment["PGM_TEST_PORT"] ?? "5432") ?? 5432 }

    static let testDatabase = "pgm_itest_db"
    static let testRole = "pgm_itest_user"
    static let testPassword = "pgm-itest-password"

    func adminConnection() async -> ConnectionManager {
        let manager = ConnectionManager()
        await manager.connect(to: .socket(
            directory: Self.socketDirectory, port: Self.port, username: NSUserName()
        ))
        return manager
    }

    /// A connection as the test role, to prove privileges are actually enforced rather than
    /// merely reported.
    func roleConnection(database: String) async -> ConnectionManager {
        let manager = ConnectionManager()
        await manager.connect(to: .socket(
            directory: Self.socketDirectory, port: Self.port,
            username: Self.testRole, password: Self.testPassword
        ))
        return manager
    }

    /// Fresh database, role and table for one test.
    func withFixture(_ body: (ConnectionManager, CatalogService, PrivilegePlanner.Context) async throws -> Void) async throws {
        let admin = await adminConnection()
        let catalog = CatalogService(connections: admin)
        try await tearDown(admin)

        try await admin.execute(.init(unsafeSQL: "CREATE ROLE \"\(Self.testRole)\" WITH LOGIN PASSWORD '\(Self.testPassword)';"))
        try await admin.execute(.init(unsafeSQL: "CREATE DATABASE \"\(Self.testDatabase)\" TEMPLATE = template0;"))
        try await admin.execute(.init(unsafeSQL: "CREATE TABLE widgets (id serial PRIMARY KEY, name text NOT NULL);"), database: Self.testDatabase)
        try await admin.execute(.init(unsafeSQL: "INSERT INTO widgets (name) VALUES ('first');"), database: Self.testDatabase)

        let context = PrivilegePlanner.Context(
            database: Self.testDatabase,
            schemas: ["public"],
            objectOwners: [NSUserName()],
            serverVersionNumber: try await admin.serverVersionNumber()
        )

        do {
            try await body(admin, catalog, context)
        } catch {
            try? await tearDown(admin)
            await admin.disconnect()
            throw error
        }
        try await tearDown(admin)
        await admin.disconnect()
    }

    func tearDown(_ admin: ConnectionManager) async throws {
        _ = try? await admin.query(.init(unsafeSQL: """
            SELECT pg_terminate_backend(pid) FROM pg_stat_activity
            WHERE datname = '\(Self.testDatabase)' AND pid <> pg_backend_pid();
            """))
        await admin.close(database: Self.testDatabase)
        _ = try? await admin.query(.init(unsafeSQL: "DROP DATABASE IF EXISTS \"\(Self.testDatabase)\" WITH (FORCE);"))
        for level in AccessLevel.allCases {
            if let group = GroupRoleNaming.groupRole(database: Self.testDatabase, level: level) {
                _ = try? await admin.query(.init(unsafeSQL: "DROP ROLE IF EXISTS \"\(group)\";"))
            }
        }
        _ = try? await admin.query(.init(unsafeSQL: "DROP ROLE IF EXISTS \"\(Self.testRole)\";"))
    }

    // MARK: Connection

    @Test("Connects over the Unix socket with no password, as a fresh cluster allows")
    func connectsOverSocket() async throws {
        let admin = await adminConnection()
        defer { Task { await admin.disconnect() } }
        let version = try await admin.serverVersionNumber()
        #expect(version >= 140000)
    }

    @Test("Catalogue queries decode")
    func catalogueQueries() async throws {
        let admin = await adminConnection()
        defer { Task { await admin.disconnect() } }
        let catalog = CatalogService(connections: admin)

        let databases = try await catalog.databases()
        #expect(databases.contains { $0.name == "postgres" })
        #expect(databases.allSatisfy { $0.sizeBytes >= 0 })

        let roles = try await catalog.roles()
        #expect(roles.contains { $0.name == NSUserName() })

        // Our own pooled connections carry application_name, so they are filterable.
        let own = try await catalog.activity(includeOwnConnections: true)
        #expect(own.contains { $0.applicationName == ConnectionManager.applicationName })
        let others = try await catalog.activity(includeOwnConnections: false)
        #expect(!others.contains { $0.applicationName == ConnectionManager.applicationName })
    }

    // MARK: Privileges — the behaviour that matters

    @Test("Read Only can SELECT but not INSERT")
    func readOnlyIsEnforced() async throws {
        try await withFixture { admin, catalog, context in
            let planner = PrivilegePlanner()
            try await admin.executeInTransaction(
                planner.provisionScript(context).sqlOnly, database: Self.testDatabase
            )
            try await admin.executeInTransaction(
                planner.assignScript(role: Self.testRole, level: .readOnly, context: context).sqlOnly,
                database: Self.testDatabase
            )

            let level = try await catalog.effectiveAccess(role: Self.testRole, database: Self.testDatabase)
            #expect(level == .level(.readOnly))

            let asRole = await roleConnection(database: Self.testDatabase)
            defer { Task { await asRole.disconnect() } }

            let rows = try await asRole.query("SELECT count(*)::int8 FROM widgets;", database: Self.testDatabase)
            #expect(try rows.first?.decode(Int64.self, context: .default) == 1)

            await #expect(throws: (any Error).self) {
                try await asRole.execute(
                    .init(unsafeSQL: "INSERT INTO widgets (name) VALUES ('nope');"), database: Self.testDatabase
                )
            }
        }
    }

    @Test("Read/Write can INSERT into a serial table — the sequence USAGE case")
    func readWriteCanInsertIntoSerialTable() async throws {
        try await withFixture { admin, catalog, context in
            let planner = PrivilegePlanner()
            try await admin.executeInTransaction(
                planner.provisionScript(context).sqlOnly, database: Self.testDatabase
            )
            try await admin.executeInTransaction(
                planner.assignScript(role: Self.testRole, level: .readWrite, context: context).sqlOnly,
                database: Self.testDatabase
            )

            #expect(try await catalog.effectiveAccess(role: Self.testRole, database: Self.testDatabase) == .level(.readWrite))

            let asRole = await roleConnection(database: Self.testDatabase)
            defer { Task { await asRole.disconnect() } }

            // Without GRANT USAGE ON SEQUENCE this fails with "permission denied for sequence".
            try await asRole.execute(
                .init(unsafeSQL: "INSERT INTO widgets (name) VALUES ('from read-write');"), database: Self.testDatabase
            )
            let rows = try await asRole.query("SELECT count(*)::int8 FROM widgets;", database: Self.testDatabase)
            #expect(try rows.first?.decode(Int64.self, context: .default) == 2)
        }
    }

    @Test("A table created later is still readable — the ALTER DEFAULT PRIVILEGES case")
    func defaultPrivilegesCoverFutureTables() async throws {
        try await withFixture { admin, catalog, context in
            let planner = PrivilegePlanner()
            try await admin.executeInTransaction(
                planner.provisionScript(context).sqlOnly, database: Self.testDatabase
            )
            try await admin.executeInTransaction(
                planner.assignScript(role: Self.testRole, level: .readOnly, context: context).sqlOnly,
                database: Self.testDatabase
            )

            // Created *after* the grants, by the same owner the default privileges name.
            try await admin.execute(
                .init(unsafeSQL: "CREATE TABLE gadgets (id serial PRIMARY KEY, label text);"),
                database: Self.testDatabase
            )
            try await admin.execute(
                .init(unsafeSQL: "INSERT INTO gadgets (label) VALUES ('later');"), database: Self.testDatabase
            )

            let asRole = await roleConnection(database: Self.testDatabase)
            defer { Task { await asRole.disconnect() } }
            let rows = try await asRole.query("SELECT count(*)::int8 FROM gadgets;", database: Self.testDatabase)
            #expect(try rows.first?.decode(Int64.self, context: .default) == 1)
        }
    }

    @Test("No Access without locking cannot stop a connection, and the app reports that honestly")
    func noAccessNeedsLockdownToStopConnections() async throws {
        try await withFixture { admin, catalog, context in
            let planner = PrivilegePlanner()
            try await admin.executeInTransaction(
                planner.provisionScript(context).sqlOnly, database: Self.testDatabase
            )
            try await admin.executeInTransaction(
                planner.assignScript(role: Self.testRole, level: .noAccess, context: context).sqlOnly,
                database: Self.testDatabase
            )

            // PUBLIC still grants CONNECT, so the role can still get in. This is exactly the
            // trap the lockdown step exists for.
            let beforeLock = await roleConnection(database: Self.testDatabase)
            _ = try await beforeLock.query("SELECT 1;", database: Self.testDatabase)
            await beforeLock.disconnect()

            try await admin.executeInTransaction(
                planner.lockdownScript(context).sqlOnly, database: Self.testDatabase
            )

            // After locking, connecting is refused outright.
            let afterLock = ConnectionManager()
            await afterLock.connect(to: .socket(
                directory: Self.socketDirectory, port: Self.port,
                username: Self.testRole, password: Self.testPassword
            ))
            await #expect(throws: (any Error).self) {
                _ = try await afterLock.query("SELECT 1;", database: Self.testDatabase)
            }
            await afterLock.disconnect()

            #expect(try await catalog.effectiveAccess(role: Self.testRole, database: Self.testDatabase) == .level(.noAccess))
        }
    }

    @Test("Privileges granted by hand outside the app are reported as Custom, not mislabelled")
    func handGrantedPrivilegesReadBackAsCustom() async throws {
        try await withFixture { admin, catalog, context in
            try await admin.executeInTransaction(
                PrivilegePlanner().provisionScript(context).sqlOnly, database: Self.testDatabase
            )
            // The sort of thing someone would type in psql.
            try await admin.execute(.init(unsafeSQL: "GRANT USAGE ON SCHEMA public TO \"\(Self.testRole)\";"), database: Self.testDatabase)
            try await admin.execute(.init(unsafeSQL: "GRANT SELECT ON widgets TO \"\(Self.testRole)\";"), database: Self.testDatabase)

            let access = try await catalog.effectiveAccess(role: Self.testRole, database: Self.testDatabase)
            guard case .custom(let reasons) = access else {
                Issue.record("Expected .custom, got \(access)")
                return
            }
            #expect(!reasons.isEmpty)
        }
    }

    // MARK: Editor & browser

    @Test("The SQL editor renders every column type as text")
    func sqlEditorRendersTypes() async throws {
        let admin = await adminConnection()
        defer { Task { await admin.disconnect() } }
        let service = QueryService(connections: admin)

        let outcomes = await service.run("""
            SELECT 42::int4 AS i, 'hello'::text AS t, true AS b, 1.5::float8 AS f,
                   now()::timestamptz AS ts, '{"a":1}'::jsonb AS j,
                   gen_random_uuid() AS u, ARRAY['x','y'] AS arr, NULL::text AS n;
            """, database: "postgres")

        let result = try #require(outcomes.first?.result)
        #expect(result.columns.count == 9)
        #expect(result.rows.first?[0] == "42")
        #expect(result.rows.first?[1] == "hello")
        #expect(result.rows.first?[2] == "t" || result.rows.first?[2] == "true")
        // NULL must come back as nil, not the string "NULL".
        #expect(result.rows.first?[8] == nil)
    }

    @Test("A failing statement reports Postgres' own message, not a generic one")
    func sqlErrorsAreReadable() async throws {
        let admin = await adminConnection()
        defer { Task { await admin.disconnect() } }
        let outcomes = await QueryService(connections: admin).run("SELECT * FROM no_such_table;", database: "postgres")
        let message = try #require(outcomes.first?.errorMessage)
        #expect(message.contains("no_such_table"))
        #expect(message.contains("42P01"))     // undefined_table
    }

    @Test("Table browsing returns columns, indexes and rows")
    func tableBrowsing() async throws {
        try await withFixture { admin, catalog, _ in
            let tables = try await catalog.tables(in: Self.testDatabase)
            let widgets = try #require(tables.first { $0.name == "widgets" })
            #expect(widgets.schema == "public")
            #expect(widgets.kind == .table)

            let columns = try await catalog.columns(of: widgets, in: Self.testDatabase)
            #expect(columns.map(\.name) == ["id", "name"])
            #expect(columns.first?.isPrimaryKey == true)
            #expect(columns.last?.isNotNull == true)

            let indexes = try await catalog.indexes(of: widgets, in: Self.testDatabase)
            #expect(indexes.contains { $0.isPrimary })

            let rows = try await catalog.rows(of: widgets, in: Self.testDatabase, limit: 10, offset: 0)
            #expect(rows.rowCount == 1)

            #expect(try await catalog.exactRowCount(of: widgets, in: Self.testDatabase) == 1)
        }
    }
}
