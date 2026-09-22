import Foundation
import Kafka
import Logging
import NIOCore
import ServiceLifecycle

/// One record read from a topic.
public struct KafkaMessage: Identifiable, Sendable {
    public let id = UUID()
    public let partition: Int
    public let offset: Int64
    public let key: String?
    public let value: String
    public let timestamp: Date?
    public let headers: [String: String]

    public init(
        partition: Int, offset: Int64, key: String?, value: String,
        timestamp: Date?, headers: [String: String]
    ) {
        self.partition = partition
        self.offset = offset
        self.key = key
        self.value = value
        self.timestamp = timestamp
        self.headers = headers
    }

    /// The value pretty-printed when it is JSON, and unchanged when it is not.
    ///
    /// Most things on a topic are JSON, and reading a minified payload in a table is miserable,
    /// so it is reformatted when it parses and left strictly alone when it does not.
    public var prettyValue: String {
        JSONFormatting.pretty(value) ?? value
    }

    public var isJSON: Bool { JSONFormatting.pretty(value) != nil }

    /// A single-line form for the message list.
    public var summary: String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }
}

public enum JSONFormatting {
    /// Pretty-print a JSON string, or return nil when it is not JSON.
    public static func pretty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cheap rejection before handing anything to the parser.
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: formatted, as: UTF8.self)
    }
}

/// Reads messages from a topic with the native Swift client.
///
/// Kafka's `kafka-console-consumer` would also work, but it starts a JVM on every read, which
/// makes browsing feel broken. This talks the Kafka protocol directly, so a refresh is instant.
public struct KafkaMessageReader: Sendable {

    public enum StartPosition: String, Sendable, CaseIterable, Identifiable {
        /// Everything the topic still retains.
        case beginning
        /// Only messages produced from now on.
        case end

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .beginning: return "From the beginning"
            case .end:       return "Only new messages"
            }
        }

        var offset: KafkaOffset {
            switch self {
            case .beginning: return .beginning
            case .end:       return .end
            }
        }
    }

    public let bootstrapServer: String

    public init(bootstrapServer: String) {
        self.bootstrapServer = bootstrapServer
    }

    private func brokerAddress() throws -> KafkaConfiguration.BrokerAddress {
        let parts = bootstrapServer.split(separator: ":")
        let host = parts.first.map(String.init) ?? "127.0.0.1"
        let port = parts.count > 1 ? Int(parts[1]) ?? 9092 : 9092
        return KafkaConfiguration.BrokerAddress(host: host, port: port)
    }

    /// Stream messages from a topic until the task is cancelled.
    ///
    /// A fresh consumer group each time means browsing never disturbs an application's committed
    /// offsets — this is a viewer, not a consumer that should remember its place.
    public func stream(
        topic: String,
        from position: StartPosition = .beginning,
        groupID: String = "dev-services-viewer-\(UUID().uuidString)"
    ) -> AsyncThrowingStream<KafkaMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var configuration = KafkaConsumerConfiguration(
                        consumptionStrategy: .group(id: groupID, topics: [topic]),
                        bootstrapBrokerAddresses: [try brokerAddress()]
                    )
                    configuration.autoOffsetReset = position == .beginning ? .beginning : .largest
                    // Nothing is committed: this is a read-only view of the topic.
                    configuration.isAutoCommitEnabled = false

                    var logger = Logger(label: "ServiceKit.KafkaMessageReader")
                    logger.logLevel = .critical

                    let consumer = try KafkaConsumer(configuration: configuration, logger: logger)
                    let group = ServiceGroup(
                        services: [consumer],
                        gracefulShutdownSignals: [],
                        logger: logger
                    )

                    let runTask = Task { try? await group.run() }
                    defer { runTask.cancel() }

                    for try await message in consumer.messages {
                        continuation.yield(Self.convert(message))
                        if Task.isCancelled { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collect up to `limit` messages, giving up after `timeout` so an empty topic does not hang
    /// the UI waiting for something that will never arrive.
    public func readBatch(
        topic: String,
        from position: StartPosition = .beginning,
        limit: Int = 100,
        timeout: Duration = .seconds(8)
    ) async throws -> [KafkaMessage] {
        try await withThrowingTaskGroup(of: [KafkaMessage].self) { group in
            group.addTask {
                var collected: [KafkaMessage] = []
                for try await message in stream(topic: topic, from: position) {
                    collected.append(message)
                    if collected.count >= limit { break }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return []
            }

            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    static func convert(_ message: KafkaConsumerMessage) -> KafkaMessage {
        var headers: [String: String] = [:]
        for header in message.headers {
            headers[header.key] = header.value.map { String(buffer: $0) } ?? ""
        }
        return KafkaMessage(
            partition: Int(message.partition.rawValue),
            offset: Int64(message.offset.rawValue),
            key: message.key.map { String(buffer: $0) },
            value: String(buffer: message.value),
            timestamp: nil,
            headers: headers
        )
    }
}

/// Publishes messages with the native client, so producing does not pay JVM startup either.
public struct KafkaMessageWriter: Sendable {

    public let bootstrapServer: String

    public init(bootstrapServer: String) {
        self.bootstrapServer = bootstrapServer
    }

    public func send(topic: String, key: String?, value: String) async throws {
        let parts = bootstrapServer.split(separator: ":")
        let host = parts.first.map(String.init) ?? "127.0.0.1"
        let port = parts.count > 1 ? Int(parts[1]) ?? 9092 : 9092

        let configuration = KafkaProducerConfiguration(
            bootstrapBrokerAddresses: [KafkaConfiguration.BrokerAddress(host: host, port: port)]
        )
        var logger = Logger(label: "ServiceKit.KafkaMessageWriter")
        logger.logLevel = .critical

        let (producer, events) = try KafkaProducer.makeProducerWithEvents(
            configuration: configuration, logger: logger
        )
        let group = ServiceGroup(services: [producer], gracefulShutdownSignals: [], logger: logger)
        let runTask = Task { try? await group.run() }
        defer { runTask.cancel() }

        let message = KafkaProducerMessage(
            topic: topic,
            key: key.map { ByteBuffer(string: $0) },
            value: value
        )
        let messageID = try producer.send(message)

        // Wait for the broker to acknowledge, so a failure is reported rather than swallowed.
        for await event in events {
            guard case .deliveryReports(let reports) = event else { continue }
            for report in reports where report.id == messageID {
                if case .failure(let error) = report.status { throw error }
                return
            }
        }
    }
}
