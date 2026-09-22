import Testing
@testable import ServiceKit

private func makeContext(
    database: String = "app",
    schemas: [String] = ["public"],
    owners: [String] = ["anuj"],
    version: Int = 180006
) -> PrivilegePlanner.Context {
    PrivilegePlanner.Context(
        database: database, schemas: schemas, objectOwners: owners, serverVersionNumber: version
    )
}

@Suite("Privilege planner")
struct PrivilegePlannerTests {

    let planner = PrivilegePlanner()

    @Test("Read/write grants USAGE on sequences, without which INSERT into a serial table fails")
    func readWriteGrantsSequenceUsage() throws {
        let sql = try planner.provisionScript(makeContext()).rendered
        #expect(sql.contains("GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA \"public\" TO \"pgm_app_rw\";"))
        #expect(sql.contains("GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO \"pgm_app_rw\""))
    }

    @Test("Default privileges are emitted once per object owner, since they are per-creating-role")
    func defaultPrivilegesPerOwner() throws {
        let sql = try planner.provisionScript(makeContext(owners: ["anuj", "alice"])).rendered
        #expect(sql.contains("ALTER DEFAULT PRIVILEGES FOR ROLE \"anuj\" IN SCHEMA \"public\""))
        #expect(sql.contains("ALTER DEFAULT PRIVILEGES FOR ROLE \"alice\" IN SCHEMA \"public\""))
    }

    @Test("Every schema is covered, not just public")
    func coversEverySchema() throws {
        let sql = try planner.provisionScript(makeContext(schemas: ["public", "billing"])).rendered
        #expect(sql.contains("IN SCHEMA \"billing\""))
        #expect(sql.contains("IN SCHEMA \"public\""))
    }

    @Test("REVOKE CREATE FROM PUBLIC is emitted below Postgres 15 and skipped at or above it")
    func publicSchemaCreateRevokeIsVersionDependent() throws {
        let old = try planner.provisionScript(makeContext(version: 140010)).rendered
        let new = try planner.provisionScript(makeContext(version: 150004)).rendered
        #expect(old.contains("REVOKE CREATE ON SCHEMA \"public\" FROM PUBLIC;"))
        #expect(!new.contains("REVOKE CREATE ON SCHEMA \"public\" FROM PUBLIC;"))
    }

    @Test("Provisioning is idempotent: running it twice produces identical SQL")
    func provisioningIsIdempotent() throws {
        let context = makeContext()
        #expect(try planner.provisionScript(context).rendered == planner.provisionScript(context).rendered)
    }

    @Test("Group roles are created guarded, so re-running does not error")
    func groupRoleCreationIsGuarded() throws {
        let sql = try planner.provisionScript(makeContext()).rendered
        #expect(sql.contains("IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgm_app_ro')"))
    }

    @Test("Assigning a level revokes the other levels before granting", arguments: [AccessLevel.readOnly, .readWrite, .owner])
    func assignRevokesBeforeGranting(level: AccessLevel) throws {
        let script = try planner.assignScript(role: "alice", level: level, context: makeContext())
        let statements = script.sqlOnly
        let revokeIndex = try #require(statements.firstIndex { $0.hasPrefix("REVOKE") })
        let grantIndex = try #require(statements.firstIndex { $0.hasPrefix("GRANT") })
        #expect(revokeIndex < grantIndex)

        let expectedGroup = try #require(GroupRoleNaming.groupRole(database: "app", level: level))
        #expect(statements.contains("GRANT \"\(expectedGroup)\" TO \"alice\";"))
        // The level being granted must not also appear in the revoke list.
        let revoke = statements[revokeIndex]
        #expect(!revoke.contains("\"\(expectedGroup)\""))
    }

    @Test("No Access revokes every group and cleans up grants made by hand")
    func noAccessAlsoCleansDirectGrants() throws {
        let sql = try planner.assignScript(role: "alice", level: .noAccess, context: makeContext()).rendered
        #expect(sql.contains("REVOKE \"pgm_app_ro\", \"pgm_app_rw\", \"pgm_app_owner\" FROM \"alice\";"))
        #expect(sql.contains("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA \"public\" FROM \"alice\";"))
        #expect(sql.contains("ALTER DEFAULT PRIVILEGES FOR ROLE \"anuj\" IN SCHEMA \"public\" REVOKE ALL ON TABLES FROM \"alice\";"))
    }

    @Test("No Access does not grant any group role")
    func noAccessGrantsNothing() throws {
        let script = try planner.assignScript(role: "alice", level: .noAccess, context: makeContext())
        #expect(!script.sqlOnly.contains { $0.hasPrefix("GRANT ") })
    }

    @Test("canCreateObjects adds CREATE on the schema for the read/write group")
    func createObjectsOption() throws {
        let without = try planner.provisionScript(makeContext(), options: .default).rendered
        let with = try planner.provisionScript(makeContext(), options: AccessOptions(canCreateObjects: true)).rendered
        #expect(!without.contains("GRANT CREATE ON SCHEMA \"public\" TO \"pgm_app_rw\";"))
        #expect(with.contains("GRANT CREATE ON SCHEMA \"public\" TO \"pgm_app_rw\";"))
    }

    @Test("canTruncate widens the table privilege list everywhere it appears")
    func truncateOption() throws {
        let sql = try planner.provisionScript(makeContext(), options: AccessOptions(canTruncate: true)).rendered
        #expect(sql.contains("GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES"))
        #expect(sql.contains("GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES"))
    }

    @Test("Locking a database revokes PUBLIC, which is what makes No Access real")
    func lockdownRevokesPublic() throws {
        let script = try planner.lockdownScript(makeContext())
        #expect(script.rendered.contains("REVOKE ALL ON DATABASE \"app\" FROM PUBLIC;"))
        #expect(script.isDestructive)
    }

    @Test("Dropping a role reassigns what it owns first")
    func dropRoleReassignsFirst() throws {
        let statements = try planner.dropRoleScript(role: "alice", reassignTo: "anuj", database: "app").sqlOnly
        #expect(statements[0] == "REASSIGN OWNED BY \"alice\" TO \"anuj\";")
        #expect(statements[1] == "DROP OWNED BY \"alice\";")
    }

    @Test("Identifiers reach the SQL quoted, so a hostile database name cannot inject")
    func hostileNamesAreQuoted() throws {
        let sql = try planner.assignScript(
            role: "ev\"il",
            level: .readOnly,
            context: makeContext(database: "app")
        ).rendered
        #expect(sql.contains("\"ev\"\"il\""))
        #expect(!sql.contains("\"ev\"il\""))
    }
}

@Suite("Group role naming")
struct GroupRoleNamingTests {

    @Test("Names follow pgm_<db>_<level>")
    func basicNames() {
        #expect(GroupRoleNaming.groupRole(database: "app", level: .readOnly) == "pgm_app_ro")
        #expect(GroupRoleNaming.groupRole(database: "app", level: .readWrite) == "pgm_app_rw")
        #expect(GroupRoleNaming.groupRole(database: "app", level: .owner) == "pgm_app_owner")
    }

    @Test("No Access is the absence of membership, so it has no group")
    func noAccessHasNoGroup() {
        #expect(GroupRoleNaming.groupRole(database: "app", level: .noAccess) == nil)
    }

    @Test("Awkward characters are sanitised")
    func sanitisation() {
        #expect(GroupRoleNaming.groupRole(database: "My-App.DB", level: .readOnly) == "pgm_my_app_db_ro")
    }

    @Test("Long names stay within Postgres' 63-byte identifier limit")
    func respectsNameDataLen() throws {
        let long = String(repeating: "d", count: 200)
        let name = try #require(GroupRoleNaming.groupRole(database: long, level: .readWrite))
        #expect(name.utf8.count <= 63)
        #expect(name.hasSuffix("_rw"))
    }

    @Test("Names that truncate to the same prefix stay distinct")
    func truncationAvoidsCollisions() throws {
        let a = try #require(GroupRoleNaming.groupRole(database: String(repeating: "x", count: 100) + "alpha", level: .readOnly))
        let b = try #require(GroupRoleNaming.groupRole(database: String(repeating: "x", count: 100) + "beta", level: .readOnly))
        #expect(a != b)
    }
}
