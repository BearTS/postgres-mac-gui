import Foundation

public struct DatabaseInfo: Identifiable, Sendable, Hashable {
    public let name: String
    public let owner: String
    public let encoding: String
    public let collation: String
    public let allowsConnections: Bool
    public let sizeBytes: Int64
    public let connectionCount: Int

    public var id: String { name }

    public init(
        name: String, owner: String, encoding: String, collation: String,
        allowsConnections: Bool, sizeBytes: Int64, connectionCount: Int
    ) {
        self.name = name
        self.owner = owner
        self.encoding = encoding
        self.collation = collation
        self.allowsConnections = allowsConnections
        self.sizeBytes = sizeBytes
        self.connectionCount = connectionCount
    }

    public var formattedSize: String { ByteFormat.string(sizeBytes) }
}

public struct TableInfo: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case table = "r"
        case partitionedTable = "p"
        case view = "v"
        case materializedView = "m"
        case foreignTable = "f"

        public var label: String {
            switch self {
            case .table:            return "Table"
            case .partitionedTable: return "Partitioned table"
            case .view:             return "View"
            case .materializedView: return "Materialized view"
            case .foreignTable:     return "Foreign table"
            }
        }

        public var isQueryableAsRows: Bool { true }
    }

    public let schema: String
    public let name: String
    public let kind: Kind
    public let owner: String
    /// Planner estimate from `pg_class.reltuples`; -1 when the table has never been analysed.
    public let rowEstimate: Int64
    public let totalBytes: Int64
    public let tableBytes: Int64

    public var id: String { "\(schema).\(name)" }
    public var qualifiedName: String { "\(schema).\(name)" }
    public var formattedSize: String { ByteFormat.string(totalBytes) }

    public init(
        schema: String, name: String, kind: Kind, owner: String,
        rowEstimate: Int64, totalBytes: Int64, tableBytes: Int64
    ) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.owner = owner
        self.rowEstimate = rowEstimate
        self.totalBytes = totalBytes
        self.tableBytes = tableBytes
    }
}

public struct ColumnInfo: Identifiable, Sendable, Hashable {
    public let position: Int
    public let name: String
    public let type: String
    public let isNotNull: Bool
    public let defaultExpression: String?
    public let isPrimaryKey: Bool

    public var id: Int { position }

    public init(position: Int, name: String, type: String, isNotNull: Bool, defaultExpression: String?, isPrimaryKey: Bool) {
        self.position = position
        self.name = name
        self.type = type
        self.isNotNull = isNotNull
        self.defaultExpression = defaultExpression
        self.isPrimaryKey = isPrimaryKey
    }
}

public struct IndexInfo: Identifiable, Sendable, Hashable {
    public let name: String
    public let definition: String
    public let isPrimary: Bool
    public let isUnique: Bool
    public let sizeBytes: Int64

    public var id: String { name }

    public init(name: String, definition: String, isPrimary: Bool, isUnique: Bool, sizeBytes: Int64) {
        self.name = name
        self.definition = definition
        self.isPrimary = isPrimary
        self.isUnique = isUnique
        self.sizeBytes = sizeBytes
    }
}

/// One row of `pg_stat_activity` — a connected client.
public struct ActivityInfo: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let user: String?
    public let database: String?
    public let applicationName: String?
    public let clientAddress: String?
    public let clientPort: Int?
    public let backendStart: Date?
    public let queryStart: Date?
    public let state: String?
    public let waitEventType: String?
    public let waitEvent: String?
    public let query: String?

    public var id: Int32 { pid }

    public init(
        pid: Int32, user: String?, database: String?, applicationName: String?,
        clientAddress: String?, clientPort: Int?, backendStart: Date?, queryStart: Date?,
        state: String?, waitEventType: String?, waitEvent: String?, query: String?
    ) {
        self.pid = pid
        self.user = user
        self.database = database
        self.applicationName = applicationName
        self.clientAddress = clientAddress
        self.clientPort = clientPort
        self.backendStart = backendStart
        self.queryStart = queryStart
        self.state = state
        self.waitEventType = waitEventType
        self.waitEvent = waitEvent
        self.query = query
    }

    /// How the client reached the server: a Unix socket has no client address.
    public var connectionKind: String {
        guard let clientAddress, !clientAddress.isEmpty else { return "Unix socket" }
        return clientAddress
    }

    public var isIdle: Bool { state == "idle" }
}

public struct RoleInfo: Identifiable, Sendable, Hashable {
    public let name: String
    public let isSuperuser: Bool
    public let canCreateDatabase: Bool
    public let canCreateRole: Bool
    public let canLogin: Bool
    public let connectionLimit: Int
    public let validUntil: Date?
    public let memberOf: [String]

    public var id: String { name }

    public init(
        name: String, isSuperuser: Bool, canCreateDatabase: Bool, canCreateRole: Bool,
        canLogin: Bool, connectionLimit: Int, validUntil: Date?, memberOf: [String]
    ) {
        self.name = name
        self.isSuperuser = isSuperuser
        self.canCreateDatabase = canCreateDatabase
        self.canCreateRole = canCreateRole
        self.canLogin = canLogin
        self.connectionLimit = connectionLimit
        self.validUntil = validUntil
        self.memberOf = memberOf
    }

    /// A role that cannot log in is a group, not a user.
    public var isLoginUser: Bool { canLogin }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}
