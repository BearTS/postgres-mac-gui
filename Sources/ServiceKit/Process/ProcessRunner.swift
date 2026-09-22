import Foundation

/// One line of output from a child process, tagged with the stream it came from.
public enum ProcessOutputLine: Sendable, Equatable {
    case stdout(String)
    case stderr(String)

    public var text: String {
        switch self {
        case .stdout(let s), .stderr(let s): return s
        }
    }

    public var isError: Bool {
        if case .stderr = self { return true }
        return false
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var isSuccess: Bool { exitCode == 0 }

    /// stderr when present, otherwise stdout — the message worth showing a user on failure.
    public var failureMessage: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

public struct ProcessError: LocalizedError, Sendable {
    public let command: String
    public let exitCode: Int32
    public let output: String

    public var errorDescription: String? {
        "`\(command)` failed with exit code \(exitCode)\n\n\(output)"
    }
}

/// Runs child processes, either collecting all output or streaming it line by line.
///
/// Every helper in ServiceKit that shells out (brew, pg_ctl, initdb, pg_dump, …) goes through here
/// so that the command and its output can be recorded in ``CommandLog`` and shown in the UI.
public enum ProcessRunner {

    /// Environment a child gets by default: the user's PATH plus Homebrew, which a GUI app
    /// launched from Finder does not otherwise inherit.
    public static func defaultEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let brewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let missing = brewPaths.filter { !existingPath.split(separator: ":").map(String.init).contains($0) }
        if !missing.isEmpty {
            env["PATH"] = (missing + [existingPath]).joined(separator: ":")
        }
        // Keep child tool output parseable regardless of the user's locale.
        env["LC_ALL"] = env["LC_ALL"] ?? "C"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Run a process to completion, collecting stdout and stderr.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async throws -> ProcessResult {
        let accumulator = OutputAccumulator()
        let code = try await streamProcess(
            executable, arguments, environment: environment, currentDirectory: currentDirectory
        ) { line in
            accumulator.append(line)
        }
        return ProcessResult(exitCode: code, stdout: accumulator.stdout, stderr: accumulator.stderr)
    }

    /// Run a process and throw if it exits non-zero. Returns trimmed stdout.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async throws -> String {
        let result = try await run(executable, arguments, environment: environment, currentDirectory: currentDirectory)
        guard result.isSuccess else {
            throw ProcessError(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                output: result.failureMessage
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run a process, delivering each output line as it arrives. Returns the exit code.
    ///
    /// The handler is called from a background queue, serially, in arrival order per stream.
    public static func streamProcess(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        onLine: @escaping @Sendable (ProcessOutputLine) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? defaultEnvironment()
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = LineCollector(onLine: onLine)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(.stdoutStream)
            } else {
                collector.ingest(data, stream: .stdoutStream)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(.stderrStream)
            } else {
                collector.ingest(data, stream: .stderrStream)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { proc in
                    // Drain anything the readability handlers have not seen yet.
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        collector.ingest(rest, stream: .stdoutStream)
                    }
                    if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        collector.ingest(rest, stream: .stderrStream)
                    }
                    collector.finish(.stdoutStream)
                    collector.finish(.stderrStream)
                    continuation.resume(returning: proc.terminationStatus)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Run a process as an `AsyncThrowingStream` of lines. The stream finishes when the process exits;
    /// a non-zero exit throws ``ProcessError`` after all lines have been delivered.
    public static func lines(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        throwOnFailure: Bool = true
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tail = TailBuffer()
                    let code = try await streamProcess(
                        executable, arguments, environment: environment, currentDirectory: currentDirectory
                    ) { line in
                        tail.append(line)
                        continuation.yield(line)
                    }
                    if code != 0 && throwOnFailure {
                        continuation.finish(throwing: ProcessError(
                            command: ([executable] + arguments).joined(separator: " "),
                            exitCode: code,
                            output: tail.text
                        ))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Run a process, writing `input` to its stdin and waiting for it to finish.
    ///
    /// Needed for tools that read from stdin rather than taking a value as an argument —
    /// Kafka's console producer being the reason this exists.
    public static func runWithInput(
        _ executable: String,
        _ arguments: [String] = [],
        input: String,
        environment: [String: String]? = nil
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? defaultEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        // Closing stdin is what tells the child there is no more input; without it the
        // console producer waits forever.
        try? inputPipe.fileHandleForWriting.close()

        let output = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProcessError(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: process.terminationStatus,
                output: String(decoding: output, as: UTF8.self)
            )
        }
    }

    /// Absolute path of a tool on PATH, or nil.
    public static func which(_ tool: String) async -> String? {
        guard let result = try? await run("/usr/bin/env", ["which", tool]) else { return nil }
        guard result.isSuccess else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

// MARK: - Internals

private enum StreamKind: Sendable {
    case stdoutStream
    case stderrStream
}

/// Splits incoming chunks into lines and forwards them, keeping a partial trailing line buffered.
/// Thread-safe: the two readability handlers run on different queues.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    private let onLine: @Sendable (ProcessOutputLine) -> Void

    init(onLine: @escaping @Sendable (ProcessOutputLine) -> Void) {
        self.onLine = onLine
    }

    func ingest(_ data: Data, stream: StreamKind) {
        var toEmit: [ProcessOutputLine] = []
        lock.lock()
        switch stream {
        case .stdoutStream:
            outBuffer.append(data)
            toEmit = Self.drain(&outBuffer).map { .stdout($0) }
        case .stderrStream:
            errBuffer.append(data)
            toEmit = Self.drain(&errBuffer).map { .stderr($0) }
        }
        lock.unlock()
        for line in toEmit { onLine(line) }
    }

    /// Flush any partial trailing line for a stream that has closed.
    func finish(_ stream: StreamKind) {
        var remainder: String?
        lock.lock()
        switch stream {
        case .stdoutStream:
            if !outBuffer.isEmpty {
                remainder = String(decoding: outBuffer, as: UTF8.self)
                outBuffer.removeAll()
            }
        case .stderrStream:
            if !errBuffer.isEmpty {
                remainder = String(decoding: errBuffer, as: UTF8.self)
                errBuffer.removeAll()
            }
        }
        lock.unlock()
        guard let remainder, !remainder.isEmpty else { return }
        onLine(stream == .stdoutStream ? .stdout(remainder) : .stderr(remainder))
    }

    private static func drain(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer = buffer[buffer.index(after: idx)...]
        }
        buffer = Data(buffer)
        return lines
    }
}

/// Keeps the last N lines of a process's output so a failure can report context.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 40

    func append(_ line: ProcessOutputLine) {
        lock.lock()
        lines.append(line.text)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Thread-safe accumulator for the non-streaming `run` helper.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func append(_ line: ProcessOutputLine) {
        lock.lock()
        switch line {
        case .stdout(let s): out += s + "\n"
        case .stderr(let s): err += s + "\n"
        }
        lock.unlock()
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return err }
}
