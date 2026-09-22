import Foundation
import Logging
import PostgresNIO

/// Owns one pooled `PostgresClient` per database and keeps their `run()` tasks alive.
///
/// `PostgresClient` binds a single database at configuration time and there is no per-query
/// switch, so browsing N databases means N clients. Each one is inert until its `run()` method
/// is executing, which is why creating a client and spawning its task happen in the same place.
public actor ConnectionManager {

    /// Sent as `application_name`; the Connections screen filters on it.
    public static let applicationName = "Dev Services"

    public struct NotConnected: LocalizedError, Sendable {
        public var errorDescription: String? { "Not connected to a Postgres server." }
    }

    public struct SocketMissing: LocalizedError, Sendable {
        public let path: String
        public var errorDescription: String? {
            "The server is running but there is no socket at \(path). Check `unix_socket_directories` in postgresql.conf."
        }
    }

    private struct Entry {
        let client: PostgresClient
        let runTask: Task<Void, Never>
        var lastUsed: Date
    }

    private var target: ConnectionTarget?
    private var entries: [String: Entry] = [:]
    private let logger: Logger

    /// Database every administrative query runs against.
    public static let adminDatabase = "postgres"

    public init(logger: Logger = Logger(label: "ServiceKit.ConnectionManager")) {
        self.logger = logger
    }

    // MARK: Target lifecycle

    public func connect(to target: ConnectionTarget) async {
        if self.target != target { await closeAll() }
        self.target = target
    }

    public func currentTarget() -> ConnectionTarget? { target }

    public func disconnect() async {
        await closeAll()
        target = nil
    }

    /// Tear down every pool. Call before a restart or port change — the pooled sockets are
    /// dead afterwards and would otherwise be handed out to the next query.
    public func closeAll() async {
        for (_, entry) in entries {
            entry.runTask.cancel()
        }
        entries.removeAll()
    }

    public func close(database: String) {
        entries.removeValue(forKey: database)?.runTask.cancel()
    }

    /// Drop pools that nothing has used for a while, so the user's own Connections screen stays clean.
    public func evictIdle(olderThan interval: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-interval)
        for (name, entry) in entries where entry.lastUsed < cutoff && name != Self.adminDatabase {
            entry.runTask.cancel()
            entries.removeValue(forKey: name)
        }
    }

    // MARK: Queries

    public func client(database: String) async throws -> PostgresClient {
        guard let target else { throw NotConnected() }
        if let existing = entries[database] {
            entries[database]?.lastUsed = Date()
            return existing.client
        }
        if let socketPath = target.socketPath, !target.socketExists {
            throw SocketMissing(path: socketPath)
        }

        let client = PostgresClient(
            configuration: target.configuration(database: database),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            backgroundLogger: logger
        )
        // The pool services no requests until run() is executing. Handing out the client before
        // that task is scheduled makes PostgresNIO log a "run() hasn't been called yet" warning
        // on the very first query, so give it a moment to start.
        let task = Task { await client.run() }
        entries[database] = Entry(client: client, runTask: task, lastUsed: Date())
        try? await Task.sleep(for: .milliseconds(50))
        return client
    }

    /// Run a query and collect every row.
    public func query(_ query: PostgresQuery, database: String? = nil) async throws -> [PostgresRow] {
        let client = try await client(database: database ?? Self.adminDatabase)
        let rows = try await client.query(query, logger: logger)
        var collected: [PostgresRow] = []
        for try await row in rows {
            collected.append(row)
        }
        return collected
    }

    /// Run a statement whose rows are not needed.
    public func execute(_ query: PostgresQuery, database: String? = nil) async throws {
        _ = try await self.query(query, database: database)
    }

    /// Run several statements in one transaction — used for privilege changes so a failure
    /// halfway leaves no partial state. Postgres makes DDL transactional, so this is genuinely
    /// all-or-nothing.
    public func executeInTransaction(_ statements: [String], database: String) async throws {
        let client = try await client(database: database)
        try await client.withConnection { connection in
            do {
                try await connection.query("BEGIN;", logger: self.logger)
                for statement in statements {
                    try await connection.query(PostgresQuery(unsafeSQL: statement), logger: self.logger)
                }
                try await connection.query("COMMIT;", logger: self.logger)
            } catch {
                _ = try? await connection.query("ROLLBACK;", logger: self.logger)
                throw error
            }
        }
    }

    /// Run one statement with a statement timeout, so a mis-click on a huge table cannot wedge
    /// the UI. The timeout is set on the same pooled connection immediately before the query.
    ///
    /// Note: PostgresNIO's `simpleQuery` is not actually the simple query protocol — in 1.33 it
    /// forwards to the extended protocol, which means it rejects multi-statement strings and
    /// wraps errors in a legacy type that drops SQLSTATE. Everything here goes through
    /// `query` for that reason, and results arrive in binary format, which is what
    /// ``CellRenderer`` exists to decode.
    public func query(
        _ sql: String,
        database: String,
        statementTimeout: String,
        readOnly: Bool = false
    ) async throws -> [PostgresRow] {
        let client = try await client(database: database)
        return try await client.withConnection { connection in
            try await connection.query(
                PostgresQuery(unsafeSQL: "SET statement_timeout = '\(statementTimeout)';"), logger: self.logger
            )
            if readOnly {
                try await connection.query("SET transaction_read_only = on;", logger: self.logger)
            }
            defer {
                Task { [logger = self.logger] in
                    _ = try? await connection.query("RESET statement_timeout; RESET transaction_read_only;", logger: logger)
                }
            }
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: self.logger)
            var collected: [PostgresRow] = []
            for try await row in rows { collected.append(row) }
            return collected
        }
    }

    /// Server version as an integer, e.g. 180006 — used to skip statements that are no-ops
    /// on newer servers.
    public func serverVersionNumber() async throws -> Int {
        let rows = try await query("SHOW server_version_num;")
        guard let first = rows.first,
              let text = try? first.decode(String.self, context: .default)
        else { return 0 }
        return Int(text) ?? 0
    }
}
