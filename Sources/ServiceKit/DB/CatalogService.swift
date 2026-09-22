import Foundation
import PostgresNIO

/// Reads the Postgres system catalogues and turns them into plain value types for the UI.
public struct CatalogService: Sendable {

    public let connections: ConnectionManager

    public init(connections: ConnectionManager) {
        self.connections = connections
    }

    // MARK: Databases

    /// `pg_database_size` throws for databases the current role cannot connect to, which would
    /// fail the whole result set — hence the `has_database_privilege` guard.
    public func databases(includeTemplates: Bool = false) async throws -> [DatabaseInfo] {
        let rows = try await connections.query("""
            SELECT d.datname::text,
                   pg_get_userbyid(d.datdba)::text AS owner,
                   pg_encoding_to_char(d.encoding)::text AS encoding,
                   d.datcollate::text,
                   d.datallowconn,
                   COALESCE(CASE WHEN has_database_privilege(current_user, d.oid, 'CONNECT')
                                 THEN pg_database_size(d.oid) END, 0)::int8 AS size_bytes,
                   (SELECT count(*) FROM pg_stat_activity a WHERE a.datid = d.oid)::int8 AS backends
            FROM pg_database d
            WHERE NOT d.datistemplate OR \(includeTemplates)
            ORDER BY d.datname;
            """)

        return try rows.map { row in
            let values = try row.decode((String, String, String, String, Bool, Int64, Int64).self, context: .default)
            return DatabaseInfo(
                name: values.0, owner: values.1, encoding: values.2, collation: values.3,
                allowsConnections: values.4, sizeBytes: values.5, connectionCount: Int(values.6)
            )
        }
    }

    public func createDatabase(named name: String, owner: String?) async throws {
        var sql = "CREATE DATABASE \(try Identifier.quote(name))"
        if let owner, !owner.isEmpty {
            sql += " WITH OWNER = \(try Identifier.quote(owner))"
        }
        // template0 avoids inheriting objects someone added to template1, which otherwise
        // shows up as duplicate-object errors during a later restore.
        sql += " TEMPLATE = template0 ENCODING = 'UTF8';"
        try await connections.execute(PostgresQuery(unsafeSQL: sql))
    }

    public func dropDatabase(named name: String, force: Bool) async throws {
        let sql = "DROP DATABASE \(try Identifier.quote(name))" + (force ? " WITH (FORCE);" : ";")
        try await connections.execute(PostgresQuery(unsafeSQL: sql))
    }

    // MARK: Schemas & tables

    public func schemas(in database: String) async throws -> [String] {
        let rows = try await connections.query("""
            SELECT n.nspname::text
            FROM pg_namespace n
            WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'
            ORDER BY (n.nspname = 'public') DESC, n.nspname;
            """, database: database)
        return try rows.map { try $0.decode(String.self, context: .default) }
    }

    public func tables(in database: String, schema: String? = nil) async throws -> [TableInfo] {
        let rows = try await connections.query("""
            SELECT n.nspname::text AS schema_name,
                   c.relname::text,
                   c.relkind::text,
                   pg_get_userbyid(c.relowner)::text AS owner,
                   c.reltuples::int8 AS estimated_rows,
                   pg_total_relation_size(c.oid)::int8 AS total_bytes,
                   pg_relation_size(c.oid)::int8 AS table_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = ANY ('{r,p,v,m,f}')
              AND n.nspname NOT LIKE 'pg\\_%'
              AND n.nspname <> 'information_schema'
              AND (\(schema == nil) OR n.nspname = \(schema ?? ""))
            ORDER BY n.nspname, c.relname;
            """, database: database)

        return try rows.map { row in
            let values = try row.decode((String, String, String, String, Int64, Int64, Int64).self, context: .default)
            return TableInfo(
                schema: values.0,
                name: values.1,
                kind: TableInfo.Kind(rawValue: values.2) ?? .table,
                owner: values.3,
                rowEstimate: values.4,
                totalBytes: values.5,
                tableBytes: values.6
            )
        }
    }

    public func columns(of table: TableInfo, in database: String) async throws -> [ColumnInfo] {
        let qualified = try Identifier.quote(schema: table.schema, name: table.name)
        let rows = try await connections.query("""
            SELECT a.attnum::int4,
                   a.attname::text,
                   format_type(a.atttypid, a.atttypmod)::text AS data_type,
                   a.attnotnull,
                   pg_get_expr(ad.adbin, ad.adrelid)::text AS default_expr,
                   EXISTS (SELECT 1 FROM pg_index i
                           WHERE i.indrelid = a.attrelid AND i.indisprimary
                             AND a.attnum = ANY (i.indkey)) AS is_primary_key
            FROM pg_attribute a
            LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            WHERE a.attrelid = \(qualified)::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum;
            """, database: database)

        return try rows.map { row in
            let values = try row.decode((Int32, String, String, Bool, String?, Bool).self, context: .default)
            return ColumnInfo(
                position: Int(values.0), name: values.1, type: values.2,
                isNotNull: values.3, defaultExpression: values.4, isPrimaryKey: values.5
            )
        }
    }

    public func indexes(of table: TableInfo, in database: String) async throws -> [IndexInfo] {
        let qualified = try Identifier.quote(schema: table.schema, name: table.name)
        let rows = try await connections.query("""
            SELECT ci.relname::text AS index_name,
                   pg_get_indexdef(i.indexrelid)::text AS definition,
                   i.indisprimary,
                   i.indisunique,
                   pg_relation_size(i.indexrelid)::int8 AS size_bytes
            FROM pg_index i
            JOIN pg_class ci ON ci.oid = i.indexrelid
            WHERE i.indrelid = \(qualified)::regclass
            ORDER BY i.indisprimary DESC, ci.relname;
            """, database: database)

        return try rows.map { row in
            let values = try row.decode((String, String, Bool, Bool, Int64).self, context: .default)
            return IndexInfo(
                name: values.0, definition: values.1, isPrimary: values.2,
                isUnique: values.3, sizeBytes: values.4
            )
        }
    }

    /// Exact row count — a sequential scan, so this is always an explicit user action.
    public func exactRowCount(of table: TableInfo, in database: String) async throws -> Int64 {
        let qualified = try Identifier.quote(schema: table.schema, name: table.name)
        let rows = try await connections.query(
            PostgresQuery(unsafeSQL: "SELECT count(*)::int8 FROM \(qualified);"), database: database
        )
        guard let first = rows.first else { return 0 }
        return try first.decode(Int64.self, context: .default)
    }

    /// A page of rows from a table, for the browser. Read-only and time-limited so a mis-click
    /// on a huge table cannot wedge the UI.
    public func rows(of table: TableInfo, in database: String, limit: Int, offset: Int) async throws -> DynamicResult {
        let qualified = try Identifier.quote(schema: table.schema, name: table.name)
        let start = Date()
        // Read-only with a timeout, so opening a billion-row table cannot wedge the UI.
        let rows = try await connections.query(
            "SELECT * FROM \(qualified) LIMIT \(limit) OFFSET \(offset);",
            database: database,
            statementTimeout: "15s",
            readOnly: true
        )
        return DynamicResult.from(rows: rows, limit: limit, duration: Date().timeIntervalSince(start))
    }

    // MARK: Connected clients

    public func activity(includeOwnConnections: Bool = false) async throws -> [ActivityInfo] {
        let rows = try await connections.query("""
            SELECT a.pid::int4,
                   a.usename::text,
                   a.datname::text,
                   a.application_name::text,
                   CASE WHEN a.client_addr IS NULL THEN NULL ELSE host(a.client_addr) END::text AS client,
                   a.client_port::int4,
                   a.backend_start,
                   a.query_start,
                   a.state::text,
                   a.wait_event_type::text,
                   a.wait_event::text,
                   left(a.query, 2000)::text AS query
            FROM pg_stat_activity a
            WHERE a.backend_type = 'client backend'
              AND (\(includeOwnConnections) OR a.application_name IS DISTINCT FROM \(ConnectionManager.applicationName))
            ORDER BY a.backend_start;
            """)

        return try rows.map { row in
            let values = try row.decode(
                (Int32, String?, String?, String?, String?, Int32?, Date?, Date?, String?, String?, String?, String?).self,
                context: .default
            )
            return ActivityInfo(
                pid: values.0, user: values.1, database: values.2, applicationName: values.3,
                clientAddress: values.4, clientPort: values.5.map(Int.init),
                backendStart: values.6, queryStart: values.7, state: values.8,
                waitEventType: values.9, waitEvent: values.10, query: values.11
            )
        }
    }

    /// Stop a running query but keep the session.
    public func cancelBackend(pid: Int32) async throws {
        try await connections.execute("SELECT pg_cancel_backend(\(pid));")
    }

    /// Disconnect a client entirely.
    public func terminateBackend(pid: Int32) async throws {
        try await connections.execute("SELECT pg_terminate_backend(\(pid));")
    }

    /// Disconnect everyone from a database — needed before dropping or restoring over it.
    public func terminateConnections(to database: String) async throws {
        try await connections.execute("""
            SELECT pg_terminate_backend(pid) FROM pg_stat_activity
            WHERE datname = \(database) AND pid <> pg_backend_pid() AND backend_type = 'client backend';
            """)
    }

    // MARK: Roles

    public func roles(includeSystemRoles: Bool = false) async throws -> [RoleInfo] {
        let rows = try await connections.query("""
            SELECT r.rolname::text,
                   r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolcanlogin,
                   r.rolconnlimit::int4,
                   r.rolvaliduntil,
                   ARRAY(SELECT g.rolname::text FROM pg_auth_members m
                           JOIN pg_roles g ON g.oid = m.roleid
                          WHERE m.member = r.oid ORDER BY 1) AS member_of
            FROM pg_roles r
            WHERE \(includeSystemRoles) OR r.rolname NOT LIKE 'pg\\_%'
            ORDER BY r.rolcanlogin DESC, r.rolname;
            """)

        return try rows.map { row in
            let values = try row.decode(
                (String, Bool, Bool, Bool, Bool, Int32, Date?, [String]).self, context: .default
            )
            return RoleInfo(
                name: values.0, isSuperuser: values.1, canCreateDatabase: values.2,
                canCreateRole: values.3, canLogin: values.4, connectionLimit: Int(values.5),
                validUntil: values.6, memberOf: values.7
            )
        }
    }

    /// Roles that currently owns objects in a schema — one `ALTER DEFAULT PRIVILEGES FOR ROLE`
    /// block is needed per owner, because default privileges are per-creating-role.
    public func objectOwners(in database: String, schema: String) async throws -> [String] {
        let rows = try await connections.query("""
            SELECT DISTINCT pg_get_userbyid(c.relowner)::text
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema) AND c.relkind = ANY ('{r,p,v,m,S,f}')
            UNION
            SELECT pg_get_userbyid(d.datdba)::text FROM pg_database d WHERE d.datname = \(database);
            """, database: database)
        return try rows.map { try $0.decode(String.self, context: .default) }.sorted()
    }

    /// Roles that can currently connect to a database — used before locking it down, so the
    /// user can see who is about to lose access.
    public func rolesRelyingOnPublic(database: String) async throws -> [String] {
        let sql = try PrivilegePlanner.rolesRelyingOnPublicSQL(database: database)
        let rows = try await connections.query(PostgresQuery(unsafeSQL: sql))
        return try rows.map { try $0.decode(String.self, context: .default) }
    }

    // MARK: Effective access

    /// What each role can actually do in a database, read back from the server rather than
    /// from whatever the app last wrote.
    public func effectiveAccess(role: String, database: String, schema: String = "public") async throws -> EffectiveAccess {
        let groups = GroupRoleNaming.allGroupRoles(database: database)
        var membership: [AccessLevel: Bool] = [:]
        for (level, group) in groups {
            let rows = try await connections.query("""
                SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = \(group))
                   AND pg_has_role(\(role), \(group), 'MEMBER');
                """, database: database)
            membership[level] = (try? rows.first?.decode(Bool.self, context: .default)) ?? false
        }

        let probeRows = try await connections.query("""
            SELECT has_database_privilege(\(role), \(database), 'CONNECT') AS can_connect,
                   COALESCE(bool_or(has_table_privilege(\(role), c.oid, 'SELECT')), false) AS any_select,
                   COALESCE(bool_or(has_table_privilege(\(role), c.oid, 'INSERT')), false) AS any_insert
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema) AND c.relkind = ANY ('{r,p}');
            """, database: database)
        let probe = try probeRows.first.map { try $0.decode((Bool, Bool, Bool).self, context: .default) }
            ?? (false, false, false)

        if membership[.owner] == true { return .level(.owner) }
        if membership[.readWrite] == true { return .level(.readWrite) }
        if membership[.readOnly] == true {
            // Read-only membership but write access from somewhere else is not read-only.
            if probe.2 { return .custom(reasons: ["In the read-only group but can also INSERT, so something grants writes directly."]) }
            return .level(.readOnly)
        }

        var reasons: [String] = []
        if probe.0 { reasons.append("Can connect to \(database) without holding any managed access level.") }
        if probe.1 { reasons.append("Can SELECT from at least one table without being in the read-only group.") }
        if probe.2 { reasons.append("Can INSERT into at least one table without being in the read/write group.") }
        return reasons.isEmpty ? .level(.noAccess) : .custom(reasons: reasons)
    }
}
