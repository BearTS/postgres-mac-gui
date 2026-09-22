import Foundation
import PostgresNIO

/// Splits an editor buffer into individual statements.
///
/// Naively splitting on `;` breaks the moment a function body, a string containing a semicolon,
/// or a comment shows up — all of which are normal in a SQL editor.
public enum StatementSplitter {

    public static func split(_ input: String) -> [String] {
        var statements: [String] = []
        var current = ""

        var inSingleQuote = false
        var inDoubleQuote = false
        var inLineComment = false
        var inBlockComment = 0
        var dollarTag: String?

        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                current.append(character)
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if inBlockComment > 0 {
                current.append(character)
                if character == "*", next == "/" {
                    current.append("/")
                    index += 2
                    inBlockComment -= 1
                    continue
                }
                if character == "/", next == "*" {
                    current.append("*")
                    index += 2
                    inBlockComment += 1
                    continue
                }
                index += 1
                continue
            }
            if let tag = dollarTag {
                current.append(character)
                if character == "$", matches(characters, at: index, tag: tag) {
                    current.append(contentsOf: tag.dropFirst())
                    index += tag.count
                    dollarTag = nil
                    continue
                }
                index += 1
                continue
            }
            if inSingleQuote {
                current.append(character)
                if character == "'" {
                    // '' is an escaped quote, not the end of the literal.
                    if next == "'" { current.append("'"); index += 2; continue }
                    inSingleQuote = false
                }
                index += 1
                continue
            }
            if inDoubleQuote {
                current.append(character)
                if character == "\"" {
                    if next == "\"" { current.append("\""); index += 2; continue }
                    inDoubleQuote = false
                }
                index += 1
                continue
            }

            switch character {
            case "'":
                inSingleQuote = true
                current.append(character)
            case "\"":
                inDoubleQuote = true
                current.append(character)
            case "-" where next == "-":
                inLineComment = true
                current.append("--")
                index += 2
                continue
            case "/" where next == "*":
                inBlockComment = 1
                current.append("/*")
                index += 2
                continue
            case "$":
                if let tag = dollarQuoteTag(characters, at: index) {
                    dollarTag = tag
                    current.append(tag)
                    index += tag.count
                    continue
                }
                current.append(character)
            case ";":
                current.append(character)
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != ";" { statements.append(trimmed) }
                current = ""
            default:
                current.append(character)
            }
            index += 1
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty, trailing != ";" { statements.append(trailing) }
        return statements
    }

    /// Reads `$$` or `$tag$` starting at `index`, if that is what is there.
    static func dollarQuoteTag(_ characters: [Character], at index: Int) -> String? {
        var cursor = index + 1
        var body = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "$" { return "$" + body + "$" }
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            body.append(character)
            cursor += 1
        }
        return nil
    }

    static func matches(_ characters: [Character], at index: Int, tag: String) -> Bool {
        let tagCharacters = Array(tag)
        guard index + tagCharacters.count <= characters.count else { return false }
        for offset in 0..<tagCharacters.count where characters[index + offset] != tagCharacters[offset] {
            return false
        }
        return true
    }
}

/// Runs ad-hoc SQL from the editor.
public struct QueryService: Sendable {

    public struct StatementOutcome: Identifiable, Sendable {
        public let id = UUID()
        public let sql: String
        public let result: DynamicResult?
        public let errorMessage: String?
        public let duration: TimeInterval

        public var succeeded: Bool { errorMessage == nil }
    }

    public let connections: ConnectionManager
    /// Rows past this are not rendered; the UI says the result was capped.
    public let rowLimit: Int

    public init(connections: ConnectionManager, rowLimit: Int = 1000) {
        self.connections = connections
        self.rowLimit = rowLimit
    }

    /// Execute each statement in order, stopping at the first failure.
    ///
    /// Statements are split client-side because Postgres' extended query protocol — the one
    /// PostgresNIO uses — accepts exactly one statement per round trip.
    public func run(_ input: String, database: String) async -> [StatementOutcome] {
        var outcomes: [StatementOutcome] = []
        for statement in StatementSplitter.split(input) {
            let start = Date()
            do {
                let rows = try await connections.query(statement, database: database, statementTimeout: "0")
                let duration = Date().timeIntervalSince(start)
                outcomes.append(StatementOutcome(
                    sql: statement,
                    result: DynamicResult.from(rows: rows, limit: rowLimit, duration: duration),
                    errorMessage: nil,
                    duration: duration
                ))
            } catch {
                outcomes.append(StatementOutcome(
                    sql: statement,
                    result: nil,
                    errorMessage: Self.describe(error),
                    duration: Date().timeIntervalSince(start)
                ))
                break
            }
        }
        return outcomes
    }

    /// Unpack a Postgres error into something worth reading — the raw description buries the
    /// message under connection metadata.
    public static func describe(_ error: Error) -> String {
        guard let psqlError = error as? PSQLError else { return error.localizedDescription }
        guard let fields = psqlError.serverInfo else { return String(describing: psqlError.code) }

        var parts: [String] = []
        if let severity = fields[.severity] { parts.append(severity) }
        if let message = fields[.message] { parts.append(message) }
        var text = parts.joined(separator: ": ")
        if let detail = fields[.detail] { text += "\nDetail: \(detail)" }
        if let hint = fields[.hint] { text += "\nHint: \(hint)" }
        if let position = fields[.position] { text += "\nPosition: \(position)" }
        if let sqlState = fields[.sqlState] { text += "\nSQLSTATE: \(sqlState)" }
        return text.isEmpty ? String(describing: psqlError.code) : text
    }
}
