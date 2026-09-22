import Foundation

public struct KafkaTopic: Identifiable, Sendable, Hashable {
    public let name: String
    public let partitionCount: Int
    public let replicationFactor: Int
    /// True for Kafka's own bookkeeping topics, which are noise in a topic list.
    public let isInternal: Bool

    public var id: String { name }

    public init(name: String, partitionCount: Int, replicationFactor: Int, isInternal: Bool) {
        self.name = name
        self.partitionCount = partitionCount
        self.replicationFactor = replicationFactor
        self.isInternal = isInternal
    }
}

/// Topic administration via Kafka's shipped command-line tools.
///
/// Each call starts a JVM, which takes a second or two — fine for creating and deleting topics,
/// which happens rarely. Reading messages goes through ``KafkaMessageReader`` instead, because
/// paying JVM startup on every refresh would make browsing unusable.
public struct KafkaAdmin: Sendable {

    public let installation: KafkaInstallation
    public let bootstrapServer: String

    public init(installation: KafkaInstallation, bootstrapServer: String) {
        self.installation = installation
        self.bootstrapServer = bootstrapServer
    }

    private var connectionArguments: [String] {
        ["--bootstrap-server", bootstrapServer]
    }

    /// The broker is reachable if it answers a topic listing.
    public func isReachable(timeout: TimeInterval = 10) async -> Bool {
        let result = try? await ProcessRunner.run(
            installation.topics, connectionArguments + ["--list", "--command-config", "/dev/null"]
        )
        // --command-config with /dev/null is rejected on some versions; fall back to a plain list.
        if result?.isSuccess == true { return true }
        let plain = try? await ProcessRunner.run(installation.topics, connectionArguments + ["--list"])
        return plain?.isSuccess ?? false
    }

    public func listTopics(includeInternal: Bool = false) async throws -> [KafkaTopic] {
        var args = connectionArguments + ["--describe"]
        if !includeInternal { args.append("--exclude-internal") }
        let output = try await ProcessRunner.runChecked(installation.topics, args)
        return Self.parseDescribe(output)
    }

    public func createTopicCommand(name: String, partitions: Int, replicationFactor: Int) -> (String, [String]) {
        (installation.topics, connectionArguments + [
            "--create", "--topic", name,
            "--partitions", String(partitions),
            "--replication-factor", String(replicationFactor),
        ])
    }

    public func createTopic(name: String, partitions: Int = 1, replicationFactor: Int = 1) async throws {
        let (exe, args) = createTopicCommand(name: name, partitions: partitions, replicationFactor: replicationFactor)
        _ = try await ProcessRunner.runChecked(exe, args)
    }

    public func deleteTopicCommand(name: String) -> (String, [String]) {
        (installation.topics, connectionArguments + ["--delete", "--topic", name])
    }

    public func deleteTopic(name: String) async throws {
        let (exe, args) = deleteTopicCommand(name: name)
        _ = try await ProcessRunner.runChecked(exe, args)
    }

    public func describeTopic(name: String) async throws -> String {
        try await ProcessRunner.runChecked(
            installation.topics, connectionArguments + ["--describe", "--topic", name]
        )
    }

    /// Send a message with the console producer. Keyed messages use `key\tvalue`.
    public func produce(topic: String, key: String?, value: String) async throws {
        var args = connectionArguments + ["--topic", topic]
        if key != nil {
            args += ["--property", "parse.key=true", "--property", "key.separator=\t"]
        }
        let payload = key.map { "\($0)\t\(value)" } ?? value
        try await ProcessRunner.runWithInput(installation.consoleProducer, args, input: payload + "\n")
    }

    public func consumerGroups() async throws -> [String] {
        let output = try await ProcessRunner.runChecked(
            installation.consumerGroups, connectionArguments + ["--list"]
        )
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Parsing

    /// `kafka-topics --describe` prints a header line per topic followed by one line per
    /// partition:
    ///
    ///     Topic: orders	TopicId: ...	PartitionCount: 3	ReplicationFactor: 1	Configs: ...
    ///     	Topic: orders	Partition: 0	Leader: 1	Replicas: 1	Isr: 1
    public static func parseDescribe(_ output: String) -> [KafkaTopic] {
        var topics: [KafkaTopic] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            // Partition lines are indented; only the header carries PartitionCount.
            guard line.contains("PartitionCount:") else { continue }
            let fields = Self.fields(in: line)
            guard let name = fields["Topic"] else { continue }
            topics.append(KafkaTopic(
                name: name,
                partitionCount: fields["PartitionCount"].flatMap(Int.init) ?? 0,
                replicationFactor: fields["ReplicationFactor"].flatMap(Int.init) ?? 0,
                isInternal: name.hasPrefix("__")
            ))
        }
        return topics.sorted { $0.name < $1.name }
    }

    /// Split a `Key: value` line on tabs, tolerating runs of spaces where tabs were expected.
    static func fields(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        let parts = line.split(whereSeparator: { $0 == "\t" })
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let key = String(piece[piece.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(piece[piece.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
