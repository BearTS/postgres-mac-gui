import Foundation
import Observation

/// A single command the app ran on the user's behalf, plus its output.
///
/// Everything the app does to the system is recorded here so the user can see exactly
/// which shell commands and SQL statements were executed — no hidden magic.
public struct CommandRecord: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case shell
        case sql
    }

    public enum Status: Sendable, Equatable {
        case running
        case succeeded
        case failed(Int32)

        public var isFinished: Bool { self != .running }
    }

    public let id = UUID()
    public let kind: Kind
    public let command: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: Status = .running
    public var output: [ProcessOutputLine] = []

    public init(kind: Kind, command: String, startedAt: Date = Date()) {
        self.kind = kind
        self.command = command
        self.startedAt = startedAt
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    public var outputText: String {
        output.map(\.text).joined(separator: "\n")
    }
}

/// Bounded, observable history of everything the app has executed.
@MainActor
@Observable
public final class CommandLog {
    public static let shared = CommandLog()

    public private(set) var records: [CommandRecord] = []
    private let limit = 200

    public init() {}

    public func begin(kind: CommandRecord.Kind, command: String) -> UUID {
        var record = CommandRecord(kind: kind, command: command)
        record.status = .running
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
        return record.id
    }

    public func append(_ id: UUID, line: ProcessOutputLine) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].output.append(line)
    }

    public func finish(_ id: UUID, exitCode: Int32) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].finishedAt = Date()
        records[idx].status = exitCode == 0 ? .succeeded : .failed(exitCode)
    }

    public func finish(_ id: UUID, error: Error?) {
        finish(id, exitCode: error == nil ? 0 : 1)
        if let error {
            append(id, line: .stderr(error.localizedDescription))
        }
    }

    public func clear() {
        records.removeAll()
    }

    /// Display form of a command line, quoting arguments that contain spaces.
    public nonisolated static func describe(_ executable: String, _ arguments: [String]) -> String {
        let parts = [executable] + arguments.map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }
        return parts.joined(separator: " ")
    }
}
