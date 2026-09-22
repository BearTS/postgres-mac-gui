import Foundation
import PostgresNIO

/// A result set from an arbitrary query, flattened to strings for display in a grid.
public struct DynamicResult: Sendable {
    public struct Column: Identifiable, Sendable, Hashable {
        public let index: Int
        public let name: String
        public let typeName: String
        public var id: Int { index }
    }

    public var columns: [Column]
    public var rows: [[String?]]
    public var rowCount: Int { rows.count }
    /// True when the result was capped; the UI says so rather than implying the query returned this many.
    public var wasTruncated: Bool
    public var duration: TimeInterval
    /// Statements such as INSERT return no columns; the UI shows a status line instead of a grid.
    public var isEmptyResult: Bool { columns.isEmpty }

    public init(columns: [Column] = [], rows: [[String?]] = [], wasTruncated: Bool = false, duration: TimeInterval = 0) {
        self.columns = columns
        self.rows = rows
        self.wasTruncated = wasTruncated
        self.duration = duration
    }

    public func csv() -> String {
        func escape(_ value: String?) -> String {
            guard let value else { return "" }
            guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [columns.map { escape($0.name) }.joined(separator: ",")]
        for row in rows {
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Build from raw rows. Cells are rendered by ``CellRenderer``, which handles the binary
    /// result format PostgresNIO always requests.
    public static func from(rows: [PostgresRow], limit: Int, duration: TimeInterval) -> DynamicResult {
        guard let first = rows.first else {
            return DynamicResult(duration: duration)
        }
        var columns: [Column] = []
        for (index, cell) in first.enumerated() {
            columns.append(Column(index: index, name: cell.columnName, typeName: CellRenderer.typeName(cell.dataType)))
        }
        var values: [[String?]] = []
        values.reserveCapacity(min(rows.count, limit))
        for row in rows.prefix(limit) {
            values.append(row.map { CellRenderer.render($0) })
        }
        return DynamicResult(
            columns: columns,
            rows: values,
            wasTruncated: rows.count > limit,
            duration: duration
        )
    }
}

/// Renders one cell as text.
///
/// PostgresNIO's extended query protocol always asks for binary result format, so a generic grid
/// cannot simply decode everything as `String` — an `int4` would come back as four bytes of
/// mojibake. This switches on the type OID for everything common and falls back to a readable
/// placeholder rather than garbage.
public enum CellRenderer {

    public static func render(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }

        // Text format means the server already stringified it for us.
        if cell.format == .text {
            return (try? cell.decode(String.self, context: .default)) ?? "<undecodable>"
        }

        switch cell.dataType {
        case .bool:
            return (try? cell.decode(Bool.self, context: .default)).map { $0 ? "true" : "false" }
        case .int2, .int4, .int8, .oid, .xid, .cid, .regproc, .regclass, .regtype:
            return (try? cell.decode(Int.self, context: .default)).map { "\($0)" }
        case .float4:
            return (try? cell.decode(Float.self, context: .default)).map { "\($0)" }
        case .float8:
            return (try? cell.decode(Double.self, context: .default)).map { "\($0)" }
        case .numeric:
            return (try? cell.decode(Decimal.self, context: .default)).map { "\($0)" }
        case .uuid:
            return (try? cell.decode(UUID.self, context: .default))?.uuidString
        case .date, .timestamp, .timestamptz:
            return (try? cell.decode(Date.self, context: .default)).map { dateFormatter.string(from: $0) }
        case .bytea:
            guard let data = try? cell.decode([UInt8].self, context: .default) else { return "<bytea>" }
            return "\\x" + data.prefix(64).map { String(format: "%02x", $0) }.joined()
                + (data.count > 64 ? "… (\(data.count) bytes)" : "")
        case .text, .varchar, .bpchar, .name, .char, .json, .jsonb, .xml, .inet, .cidr, .macaddr:
            return (try? cell.decode(String.self, context: .default)) ?? "<undecodable>"
        case .textArray, .varcharArray, .nameArray:
            return (try? cell.decode([String].self, context: .default))?.joined(separator: ", ")
        case .int2Array, .int4Array, .int8Array:
            return (try? cell.decode([Int].self, context: .default))?.map { "\($0)" }.joined(separator: ", ")
        default:
            // Anything else: the server's own text rendering is not available here, so say so
            // plainly instead of printing bytes that look like corrupted text.
            if let string = try? cell.decode(String.self, context: .default), string.allSatisfy({ !$0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace || $0.isSymbol }) {
                return string
            }
            return "<\(typeName(cell.dataType))>"
        }
    }

    public static func typeName(_ type: PostgresDataType) -> String {
        String(describing: type)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
