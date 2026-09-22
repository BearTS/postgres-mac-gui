import Foundation
import Testing
@testable import ServiceKit

/// Kept outside the suite: a `@Suite` condition cannot reference a static member of the type it
/// is attached to without creating a circular macro reference.
enum KafkaTestEnvironment {
    static let binDir = "/opt/homebrew/opt/kafka/bin"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binDir + "/kafka-server-start")
    }
}

/// Starts a real Kafka broker on spare ports, exercises it, and shuts it down.
///
/// Booting Kafka takes tens of seconds, so the whole suite shares one broker rather than
/// starting one per test.
@Suite("Kafka live", .enabled(if: KafkaTestEnvironment.isInstalled), .serialized)
final class KafkaLiveTests {

    /// Ports of their own, so a broker the user is already running is left alone.
    static let testPort = 9192
    static let testControllerPort = 9193

    let installation: KafkaInstallation
    let server: KafkaServer
    let admin: KafkaAdmin
    let spec: ServiceProcessSpec
    let brokerIsUp: Bool

    init() async throws {
        installation = try #require(await KafkaInstallation.discover())
        let realServer = KafkaServer(
            installation: installation, port: Self.testPort, controllerPort: Self.testControllerPort
        )
        // Redirect storage and PID/log files so a test run never touches the real broker's data.
        server = realServer
        admin = KafkaAdmin(installation: installation, bootstrapServer: realServer.bootstrapServer)
        spec = ServiceProcessSpec(
            name: "kafka-test",
            executable: realServer.spec.executable,
            arguments: realServer.spec.arguments,
            environment: realServer.spec.environment
        )

        await ProcessSupervisor.shared.stop(spec)
        try? server.resetStorage()

        var formatted = true
        do {
            for try await _ in server.format() {}
        } catch {
            formatted = false
            Issue.record("kafka-storage format failed: \(error)")
        }

        guard formatted else {
            brokerIsUp = false
            return
        }

        try await ProcessSupervisor.shared.start(spec)
        let adminCopy = admin
        brokerIsUp = await ProcessSupervisor.shared.waitUntilReady(spec, timeout: .seconds(90)) {
            await adminCopy.isReachable()
        }
        if !brokerIsUp {
            Issue.record("Kafka did not become ready.\n\(ProcessSupervisor.shared.recentLog(spec) ?? "")")
        }
    }

    deinit {
        let spec = self.spec
        let server = self.server
        // Detached because deinit cannot await, and leaving a broker running would poison
        // the next run.
        Task.detached {
            await ProcessSupervisor.shared.stop(spec, gracePeriod: .seconds(20))
            try? server.resetStorage()
        }
    }

    @Test("A single-node KRaft broker formats and starts")
    func brokerStarts() async throws {
        #expect(brokerIsUp)
        #expect(server.isFormatted)
        #expect(ProcessSupervisor.shared.status(spec).isRunning)
    }

    @Test("Topics can be created, listed, described and deleted")
    func topicLifecycle() async throws {
        try #require(brokerIsUp)
        let name = "dev-services-test-topic"

        try await admin.createTopic(name: name, partitions: 2, replicationFactor: 1)

        let topics = try await admin.listTopics()
        let topic = try #require(topics.first { $0.name == name })
        #expect(topic.partitionCount == 2)
        #expect(topic.replicationFactor == 1)
        #expect(!topic.isInternal)

        let description = try await admin.describeTopic(name: name)
        #expect(description.contains(name))

        try await admin.deleteTopic(name: name)
        // Deletion is asynchronous, so give the broker a moment to catch up.
        try await Task.sleep(for: .seconds(2))
        #expect(!(try await admin.listTopics()).contains { $0.name == name })
    }

    @Test("Messages produced with the native client are read back by it")
    func produceAndConsume() async throws {
        try #require(brokerIsUp)
        let topic = "dev-services-roundtrip"
        try await admin.createTopic(name: topic, partitions: 1, replicationFactor: 1)

        let writer = KafkaMessageWriter(bootstrapServer: server.bootstrapServer)
        try await writer.send(topic: topic, key: "k1", value: #"{"order":1,"status":"new"}"#)
        try await writer.send(topic: topic, key: nil, value: "plain text payload")

        let reader = KafkaMessageReader(bootstrapServer: server.bootstrapServer)
        let messages = try await reader.readBatch(topic: topic, from: .beginning, limit: 2, timeout: .seconds(30))

        #expect(messages.count == 2)
        let jsonMessage = try #require(messages.first { $0.key == "k1" })
        #expect(jsonMessage.isJSON)
        // JSON payloads are reformatted for reading; the raw value is untouched.
        #expect(jsonMessage.prettyValue.contains("\"order\" : 1"))

        let plain = try #require(messages.first { $0.key == nil })
        #expect(plain.value == "plain text payload")
        #expect(!plain.isJSON)

        try? await admin.deleteTopic(name: topic)
    }

    @Test("Resetting the broker's storage removes its topics")
    func resetClearsTopics() async throws {
        try #require(brokerIsUp)
        let topic = "dev-services-reset-check"
        try await admin.createTopic(name: topic, partitions: 1, replicationFactor: 1)
        #expect((try await admin.listTopics()).contains { $0.name == topic })

        await ProcessSupervisor.shared.stop(spec, gracePeriod: .seconds(20))
        try server.resetStorage()
        #expect(!server.isFormatted)

        // Bring it back so the remaining tests still have a broker.
        for try await _ in server.format() {}
        try await ProcessSupervisor.shared.start(spec)
        let adminCopy = admin
        let back = await ProcessSupervisor.shared.waitUntilReady(spec, timeout: .seconds(90)) {
            await adminCopy.isReachable()
        }
        try #require(back)
        #expect(!(try await admin.listTopics()).contains { $0.name == topic })
    }
}

@Suite("Kafka configuration")
struct KafkaConfigurationTests {

    let installation = KafkaInstallation(
        binDir: "/opt/homebrew/opt/kafka/bin", version: "4.3.1",
        packagedConfigPath: "/opt/homebrew/etc/kafka/server.properties"
    )

    @Test("The version is read from the client jar rather than by booting a JVM")
    func parsesVersionFromJars() {
        let names = ["kafka-clients-4.3.1.jar", "slf4j-api-2.0.9.jar", "kafka-clients-4.3.1-sources.jar"]
        #expect(KafkaInstallation.parseVersion(fromJarNames: names) == "4.3.1")
        #expect(KafkaInstallation.parseVersion(fromJarNames: ["slf4j-api-2.0.9.jar"]) == nil)
    }

    @Test("Kafka 4 needs KRaft formatting; Kafka 3 did not")
    func kraftDetection() {
        #expect(installation.requiresKRaft)
        let older = KafkaInstallation(binDir: "/x", version: "3.9.0", packagedConfigPath: nil)
        #expect(!older.requiresKRaft)
    }

    @Test("The generated config describes a single node acting as broker and controller")
    func configFileContents() {
        let config = KafkaServer(installation: installation, port: 9092, controllerPort: 9093).configFileContents()
        #expect(config.contains("process.roles=broker,controller"))
        #expect(config.contains("controller.quorum.voters=1@127.0.0.1:9093"))
        #expect(config.contains("PLAINTEXT://127.0.0.1:9092"))
        // Nowhere to replicate to on one node, so every replication factor must be 1.
        #expect(config.contains("offsets.topic.replication.factor=1"))
        #expect(config.contains("transaction.state.log.replication.factor=1"))
    }

    @Test("Formatting passes --ignore-formatted so re-running is not an error")
    func formatCommandIsIdempotent() {
        let server = KafkaServer(installation: installation)
        let (exe, args) = server.formatCommand(clusterID: "abc")
        #expect(exe.hasSuffix("kafka-storage"))
        #expect(args.contains("--ignore-formatted"))
        #expect(args.contains("abc"))
    }

    @Test("`kafka-topics --describe` output is parsed into topics")
    func parsesDescribeOutput() {
        let output = """
        Topic: orders\tTopicId: abc123\tPartitionCount: 3\tReplicationFactor: 1\tConfigs: cleanup.policy=delete
        \tTopic: orders\tPartition: 0\tLeader: 1\tReplicas: 1\tIsr: 1
        \tTopic: orders\tPartition: 1\tLeader: 1\tReplicas: 1\tIsr: 1
        Topic: __consumer_offsets\tTopicId: def456\tPartitionCount: 50\tReplicationFactor: 1\tConfigs:
        """
        let topics = KafkaAdmin.parseDescribe(output)
        #expect(topics.count == 2)

        let orders = try? #require(topics.first { $0.name == "orders" })
        #expect(orders?.partitionCount == 3)
        #expect(orders?.replicationFactor == 1)
        #expect(orders?.isInternal == false)

        // Kafka's own bookkeeping topics start with __ and are noise in a topic list.
        #expect(topics.first { $0.name == "__consumer_offsets" }?.isInternal == true)
    }

    @Test("JSON payloads are reformatted and everything else is left alone")
    func jsonFormatting() {
        let pretty = JSONFormatting.pretty(#"{"b":2,"a":1}"#)
        #expect(pretty?.contains("\"a\" : 1") == true)
        // Keys are sorted so the same payload always renders identically.
        #expect(pretty?.firstRange(of: "\"a\"")?.lowerBound ?? pretty!.endIndex
                < pretty?.firstRange(of: "\"b\"")?.lowerBound ?? pretty!.startIndex)

        #expect(JSONFormatting.pretty("[1, 2, 3]") != nil)
        #expect(JSONFormatting.pretty("plain text") == nil)
        #expect(JSONFormatting.pretty("") == nil)
        // A bare number is valid JSON but formatting it would be pointless noise.
        #expect(JSONFormatting.pretty("42") == nil)
    }
}
