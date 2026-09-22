import Foundation

/// Turns a chosen access level into the exact SQL that implements it.
///
/// Three things make hand-written GRANTs go wrong, and all three are handled here:
///
/// 1. **PUBLIC still grants CONNECT.** Every role is implicitly a member of `PUBLIC`, which holds
///    `CONNECT` on every database by default. `REVOKE CONNECT ... FROM alice` therefore does
///    nothing on its own — she still connects through PUBLIC. Real "No Access" needs
///    `REVOKE ALL ON DATABASE ... FROM PUBLIC`, which affects everyone, so it is a deliberate,
///    clearly-labelled one-time step (``lockdownScript``) rather than something applied silently.
/// 2. **`ALTER DEFAULT PRIVILEGES` is per-creating-role.** It only covers objects created by the
///    role named in `FOR ROLE`. A rule written for one owner does nothing for tables another role
///    creates, so the planner emits one block per object owner it was told about.
/// 3. **Sequences need USAGE, not just SELECT.** Without `USAGE ON SEQUENCE`, an INSERT into a
///    table with a `serial` column fails with "permission denied for sequence".
public struct PrivilegePlanner: Sendable {

    /// Everything the planner needs to know about the database it is writing SQL for.
    public struct Context: Sendable {
        public let database: String
        /// Non-system schemas the level should apply to. Usually just `public`.
        public let schemas: [String]
        /// Every role that currently owns objects in those schemas, plus the database owner.
        /// One `ALTER DEFAULT PRIVILEGES FOR ROLE` block is emitted per entry.
        public let objectOwners: [String]
        /// From `SHOW server_version_num`, e.g. 180006. Used to skip statements that are
        /// no-ops on newer servers.
        public let serverVersionNumber: Int

        public init(database: String, schemas: [String], objectOwners: [String], serverVersionNumber: Int) {
            self.database = database
            self.schemas = schemas.isEmpty ? ["public"] : schemas
            self.objectOwners = objectOwners.isEmpty ? [NSUserName()] : Array(Set(objectOwners)).sorted()
            self.serverVersionNumber = serverVersionNumber
        }

        /// From Postgres 15, PUBLIC no longer holds CREATE on schema `public`.
        var publicSchemaGrantsCreateToPublic: Bool { serverVersionNumber < 150000 }
    }

    public init() {}

    // MARK: Provisioning

    /// Create the group roles and give them their privileges. Idempotent: safe to re-run, and
    /// re-running is how newly created tables and new object owners get picked up.
    public func provisionScript(_ context: Context, options: AccessOptions = .default) throws -> SQLScript {
        var script = SQLScript(
            title: "Enable managed access on \(context.database)",
            database: context.database
        )
        let database = try Identifier.quote(context.database)

        guard let readOnlyGroup = GroupRoleNaming.groupRole(database: context.database, level: .readOnly),
              let readWriteGroup = GroupRoleNaming.groupRole(database: context.database, level: .readWrite),
              let ownerGroup = GroupRoleNaming.groupRole(database: context.database, level: .owner)
        else { return script }

        // 1. Group roles. NOLOGIN: they carry privileges, nobody signs in as them.
        for group in [readOnlyGroup, readWriteGroup, ownerGroup] {
            let literal = try Identifier.literal(group)
            script.add(
                """
                DO $pgm$ BEGIN
                  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = \(literal)) THEN
                    CREATE ROLE \(try Identifier.quote(group)) NOLOGIN;
                  END IF;
                END $pgm$;
                """,
                because: "Create the \(group) group role if it does not exist yet."
            )
        }

        // 2. Database-level privileges.
        script.add(
            "GRANT CONNECT, TEMPORARY ON DATABASE \(database) TO \(try Identifier.quote(readOnlyGroup)), \(try Identifier.quote(readWriteGroup));",
            because: "Let read-only and read/write members connect to \(context.database)."
        )
        script.add(
            "GRANT ALL PRIVILEGES ON DATABASE \(database) TO \(try Identifier.quote(ownerGroup));",
            because: "Give the owner group full control of the database."
        )

        // 3. Per-schema privileges on objects that exist right now.
        for schema in context.schemas {
            let quotedSchema = try Identifier.quote(schema)

            if schema == "public" && context.publicSchemaGrantsCreateToPublic {
                script.add(
                    "REVOKE CREATE ON SCHEMA \(quotedSchema) FROM PUBLIC;",
                    because: "Before Postgres 15 every role could create tables in `public`; take that away so levels mean something.",
                    destructive: true
                )
            }

            script.add(
                "GRANT USAGE ON SCHEMA \(quotedSchema) TO \(try Identifier.quote(readOnlyGroup)), \(try Identifier.quote(readWriteGroup));",
                because: "Allow both groups to look inside the \(schema) schema."
            )
            script.add(
                "GRANT USAGE, CREATE ON SCHEMA \(quotedSchema) TO \(try Identifier.quote(ownerGroup));",
                because: "Let the owner group create objects in \(schema)."
            )
            script.add(
                "GRANT SELECT ON ALL TABLES IN SCHEMA \(quotedSchema) TO \(try Identifier.quote(readOnlyGroup));",
                because: "Read access to every table that exists in \(schema) today."
            )
            script.add(
                "GRANT SELECT ON ALL SEQUENCES IN SCHEMA \(quotedSchema) TO \(try Identifier.quote(readOnlyGroup));",
                because: "Let read-only members read sequence values."
            )
            script.add(
                "GRANT \(Self.tablePrivileges(options)) ON ALL TABLES IN SCHEMA \(quotedSchema) TO \(try Identifier.quote(readWriteGroup));",
                because: "Write access to every table that exists in \(schema) today."
            )
            script.add(
                "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA \(quotedSchema) TO \(try Identifier.quote(readWriteGroup));",
                because: "USAGE on sequences is what makes INSERT work on tables with a serial column."
            )
            if options.canCreateObjects {
                script.add(
                    "GRANT CREATE ON SCHEMA \(quotedSchema) TO \(try Identifier.quote(readWriteGroup));",
                    because: "Let read/write members create and alter tables, as migrations need."
                )
            }

            // 4. Future objects, one block per creating role.
            for owner in context.objectOwners {
                let quotedOwner = try Identifier.quote(owner)
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) GRANT SELECT ON TABLES TO \(try Identifier.quote(readOnlyGroup));",
                    because: "Tables \(owner) creates later are readable by read-only members automatically."
                )
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) GRANT SELECT ON SEQUENCES TO \(try Identifier.quote(readOnlyGroup));",
                    because: "Same for sequences \(owner) creates later."
                )
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) GRANT \(Self.tablePrivileges(options)) ON TABLES TO \(try Identifier.quote(readWriteGroup));",
                    because: "Tables \(owner) creates later are writable by read/write members automatically."
                )
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO \(try Identifier.quote(readWriteGroup));",
                    because: "Sequences \(owner) creates later stay usable for INSERT."
                )
            }
        }
        return script
    }

    /// Revoke PUBLIC's implicit access so that "No Access" genuinely means it.
    ///
    /// This affects **every** role that is not explicitly granted a level, which is why it is a
    /// separate, explicit action. ``rolesRelyingOnPublicSQL`` finds who would be cut off.
    public func lockdownScript(_ context: Context) throws -> SQLScript {
        var script = SQLScript(title: "Lock \(context.database)", database: context.database)
        script.add(
            "REVOKE ALL ON DATABASE \(try Identifier.quote(context.database)) FROM PUBLIC;",
            because: "PUBLIC holds CONNECT on every database by default. Until this runs, revoking a role's access changes nothing.",
            destructive: true
        )
        return script
    }

    /// Roles that can currently connect only because of PUBLIC — offer to grant them a level first.
    public static func rolesRelyingOnPublicSQL(database: String) throws -> String {
        """
        SELECT r.rolname
        FROM pg_roles r
        WHERE r.rolcanlogin
          AND NOT r.rolsuper
          AND r.rolname NOT LIKE 'pg\\_%'
          AND has_database_privilege(r.rolname, \(try Identifier.literal(database)), 'CONNECT')
        ORDER BY r.rolname;
        """
    }

    // MARK: Assigning a level

    /// Move a role to a level. Revocations come first so the transaction never widens access
    /// before narrowing it.
    public func assignScript(
        role: String,
        level: AccessLevel,
        context: Context,
        disconnectExistingSessions: Bool = false
    ) throws -> SQLScript {
        var script = SQLScript(
            title: "Set \(role) to \(level.label) on \(context.database)",
            database: context.database
        )
        let quotedRole = try Identifier.quote(role)
        let groups = GroupRoleNaming.allGroupRoles(database: context.database)
        let target = GroupRoleNaming.groupRole(database: context.database, level: level)

        let toRevoke = groups.filter { $0.role != target }.map(\.role)
        if !toRevoke.isEmpty {
            let list = try toRevoke.map { try Identifier.quote($0) }.joined(separator: ", ")
            script.add(
                "REVOKE \(list) FROM \(quotedRole);",
                because: "Remove any other access level \(role) currently holds on \(context.database).",
                destructive: level == .noAccess
            )
        }

        if let target {
            script.add(
                "GRANT \(try Identifier.quote(target)) TO \(quotedRole);",
                because: "\(level.explanation)"
            )
        } else {
            // No Access also has to undo grants made by hand outside this app, or the level is a lie.
            script.append(contentsOf: try directGrantCleanupScript(role: role, context: context))
        }

        if disconnectExistingSessions {
            script.add(
                """
                SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE datname = \(try Identifier.literal(context.database))
                  AND usename = \(try Identifier.literal(role))
                  AND pid <> pg_backend_pid();
                """,
                because: "Existing sessions keep the privileges they connected with, so close them.",
                destructive: true
            )
        }
        return script
    }

    /// Strip privileges granted directly to a role, as opposed to through a group.
    public func directGrantCleanupScript(role: String, context: Context) throws -> SQLScript {
        var script = SQLScript(title: "Remove direct grants for \(role)", database: context.database)
        let quotedRole = try Identifier.quote(role)

        script.add(
            "REVOKE ALL PRIVILEGES ON DATABASE \(try Identifier.quote(context.database)) FROM \(quotedRole);",
            because: "Drop any database-level privileges granted to \(role) directly.",
            destructive: true
        )
        for schema in context.schemas {
            let quotedSchema = try Identifier.quote(schema)
            script.add(
                "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA \(quotedSchema) FROM \(quotedRole);",
                because: "Drop table privileges granted to \(role) directly in \(schema).",
                destructive: true
            )
            script.add(
                "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA \(quotedSchema) FROM \(quotedRole);",
                because: "Drop sequence privileges granted to \(role) directly in \(schema).",
                destructive: true
            )
            script.add(
                "REVOKE ALL PRIVILEGES ON SCHEMA \(quotedSchema) FROM \(quotedRole);",
                because: "Drop schema privileges granted to \(role) directly.",
                destructive: true
            )
            for owner in context.objectOwners {
                let quotedOwner = try Identifier.quote(owner)
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) REVOKE ALL ON TABLES FROM \(quotedRole);",
                    because: "Stop future tables from \(owner) being granted to \(role) directly.",
                    destructive: true
                )
                script.add(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE \(quotedOwner) IN SCHEMA \(quotedSchema) REVOKE ALL ON SEQUENCES FROM \(quotedRole);",
                    because: "Same for future sequences from \(owner).",
                    destructive: true
                )
            }
        }
        return script
    }

    // MARK: Roles

    public func createRoleScript(name: String, password: String?, canLogin: Bool = true, database: String) throws -> SQLScript {
        var script = SQLScript(title: "Create role \(name)", database: database)
        var clauses = [canLogin ? "LOGIN" : "NOLOGIN", "INHERIT"]
        if let password, !password.isEmpty {
            clauses.append("PASSWORD \(try Identifier.literal(password))")
        }
        script.add(
            "CREATE ROLE \(try Identifier.quote(name)) WITH \(clauses.joined(separator: " "));",
            because: canLogin ? "Create a login user named \(name)." : "Create a group role named \(name)."
        )
        return script
    }

    public func setPasswordScript(role: String, password: String, database: String) throws -> SQLScript {
        var script = SQLScript(title: "Set password for \(role)", database: database)
        script.add(
            "ALTER ROLE \(try Identifier.quote(role)) WITH PASSWORD \(try Identifier.literal(password));",
            because: "Change the password for \(role)."
        )
        return script
    }

    /// `DROP ROLE` fails while the role owns anything, and ownership is per-database — so the
    /// caller must run the reassign/drop pair once per database before the final DROP.
    public func dropRoleScript(role: String, reassignTo: String, database: String) throws -> SQLScript {
        var script = SQLScript(title: "Drop role \(role)", database: database)
        let quotedRole = try Identifier.quote(role)
        script.add(
            "REASSIGN OWNED BY \(quotedRole) TO \(try Identifier.quote(reassignTo));",
            because: "Hand anything \(role) owns in this database to \(reassignTo); DROP ROLE fails otherwise.",
            destructive: true
        )
        script.add(
            "DROP OWNED BY \(quotedRole);",
            because: "Remove privileges \(role) holds in this database.",
            destructive: true
        )
        return script
    }

    public func finalDropRoleScript(role: String, database: String) throws -> SQLScript {
        var script = SQLScript(title: "Drop role \(role)", database: database)
        script.add(
            "DROP ROLE \(try Identifier.quote(role));",
            because: "Remove the role from the cluster.",
            destructive: true
        )
        return script
    }

    // MARK: Helpers

    static func tablePrivileges(_ options: AccessOptions) -> String {
        var privileges = ["SELECT", "INSERT", "UPDATE", "DELETE"]
        if options.canTruncate {
            privileges += ["TRUNCATE", "REFERENCES", "TRIGGER"]
        }
        return privileges.joined(separator: ", ")
    }
}
