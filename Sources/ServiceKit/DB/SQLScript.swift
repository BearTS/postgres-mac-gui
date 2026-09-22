import Foundation

/// One SQL statement plus a plain-English reason, so the preview sheet can explain itself.
public struct SQLStatement: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let sql: String
    public let rationale: String
    public let isDestructive: Bool

    public init(_ sql: String, because rationale: String, destructive: Bool = false) {
        self.sql = sql
        self.rationale = rationale
        self.isDestructive = destructive
    }
}

/// An ordered set of statements applied as a single transaction.
///
/// Nothing in this app changes privileges without showing the user this script first.
public struct SQLScript: Sendable, Hashable {
    public var title: String
    public var statements: [SQLStatement]
    /// Database the script must be run against. Database-level GRANTs work from anywhere,
    /// but schema- and table-scoped ones only affect the database you are connected to.
    public var database: String

    public init(title: String, database: String, statements: [SQLStatement] = []) {
        self.title = title
        self.database = database
        self.statements = statements
    }

    public var isEmpty: Bool { statements.isEmpty }
    public var isDestructive: Bool { statements.contains(where: \.isDestructive) }

    public mutating func add(_ sql: String, because rationale: String, destructive: Bool = false) {
        statements.append(SQLStatement(sql, because: rationale, destructive: destructive))
    }

    public mutating func append(contentsOf other: SQLScript) {
        statements.append(contentsOf: other.statements)
    }

    /// The script as the user would paste it into psql.
    public var rendered: String {
        statements.map { "-- \($0.rationale)\n\($0.sql)" }.joined(separator: "\n\n")
    }

    public var sqlOnly: [String] { statements.map(\.sql) }
}
