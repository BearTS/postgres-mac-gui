import Foundation

/// Streams a growing log file, starting from the last N lines.
///
/// This is what makes a failed start explainable: "port already in use" and "data directory is
/// owned by the wrong user" only ever appear in the server log, never in `pg_ctl`'s own output.
public actor LogTailer {

    public struct Line: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let text: String

        /// Postgres prefixes severity in the log line itself.
        public var isError: Bool {
            text.contains("ERROR:") || text.contains("FATAL:") || text.contains("PANIC:")
        }

        public var isWarning: Bool { text.contains("WARNING:") }
    }

    private var handle: FileHandle?
    private var pollTask: Task<Void, Never>?

    public init() {}

    /// Emit the tail of the file, then every line appended afterwards.
    public func tail(path: String, initialLines: Int = 200, pollInterval: Duration = .seconds(1)) -> AsyncStream<Line> {
        AsyncStream { continuation in
            let task = Task {
                guard let handle = FileHandle(forReadingAtPath: path) else {
                    continuation.yield(Line(text: "Log file not found: \(path)"))
                    continuation.finish()
                    return
                }
                defer { try? handle.close() }

                // Seed with the existing tail so the view is not blank on open.
                if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                    let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    for line in lines.suffix(initialLines) where !line.isEmpty {
                        continuation.yield(Line(text: line))
                    }
                }
                try? handle.seekToEnd()

                var partial = ""
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty {
                        try? await Task.sleep(for: pollInterval)
                        continue
                    }
                    partial += String(decoding: data, as: UTF8.self)
                    while let newline = partial.firstIndex(of: "\n") {
                        let line = String(partial[partial.startIndex..<newline])
                        partial = String(partial[partial.index(after: newline)...])
                        if !line.isEmpty { continuation.yield(Line(text: line)) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        try? handle?.close()
        handle = nil
    }
}
