import Foundation

/// Runs a single-node Kafka broker in KRaft mode.
///
/// Kafka 4 dropped ZooKeeper, so a broker is also its own controller and its storage has to be
/// formatted with a cluster ID before it will start. That formatting step is the part people
/// most often miss, so the app does it automatically and says what it ran.
public struct KafkaServer: Sendable {

    public static let serviceName = "kafka"

    public let installation: KafkaInstallation
    public let port: Int
    public let controllerPort: Int

    public init(installation: KafkaInstallation, port: Int = 9092, controllerPort: Int = 9093) {
        self.installation = installation
        self.port = port
        self.controllerPort = controllerPort
    }

    public var bootstrapServer: String { "127.0.0.1:\(port)" }

    /// Our own config and log directory, kept away from Homebrew's so a reset never deletes
    /// something the user set up by hand.
    public var dataDirectory: String { AppPaths.dataDirectory + "/kafka" }
    public var configPath: String { AppPaths.applicationSupport + "/kafka-server.properties" }
    public var clusterIDPath: String { dataDirectory + "/cluster-id" }

    /// A single-node KRaft broker: one process acting as both broker and controller, with
    /// replication of one because there is nowhere else to replicate to.
    public func configFileContents() -> String {
        """
        # Written by Dev Services. Single-node KRaft broker for local development.
        process.roles=broker,controller
        node.id=1
        controller.quorum.voters=1@127.0.0.1:\(controllerPort)

        listeners=PLAINTEXT://127.0.0.1:\(port),CONTROLLER://127.0.0.1:\(controllerPort)
        advertised.listeners=PLAINTEXT://127.0.0.1:\(port)
        controller.listener.names=CONTROLLER
        listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
        inter.broker.listener.name=PLAINTEXT

        log.dirs=\(dataDirectory)/logs

        # One node, so nothing can be replicated anywhere else.
        offsets.topic.replication.factor=1
        transaction.state.log.replication.factor=1
        transaction.state.log.min.isr=1
        default.replication.factor=1
        num.partitions=1

        # Convenient locally, and the reason a typo in a topic name silently "works".
        auto.create.topics.enable=true

        # Small numbers suit a laptop; the defaults assume a real cluster.
        num.network.threads=3
        num.io.threads=8
        log.retention.hours=168
        group.initial.rebalance.delay.ms=0
        """
    }

    public var isFormatted: Bool {
        FileManager.default.fileExists(atPath: dataDirectory + "/logs/meta.properties")
    }

    public func writeConfigFile() throws {
        AppPaths.ensureDirectories()
        try FileManager.default.createDirectory(atPath: dataDirectory + "/logs", withIntermediateDirectories: true)
        try configFileContents().write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: Formatting

    public func generateClusterIDCommand() -> (String, [String]) {
        (installation.storage, ["random-uuid"])
    }

    public func formatCommand(clusterID: String) -> (String, [String]) {
        (installation.storage, ["format", "-t", clusterID, "-c", configPath, "--ignore-formatted"])
    }

    /// Create the cluster ID and format the log directory. Safe to call again: `--ignore-formatted`
    /// makes a second run a no-op rather than an error.
    public func format() -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try writeConfigFile()

                    let clusterID: String
                    if let existing = try? String(contentsOfFile: clusterIDPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
                        clusterID = existing
                    } else {
                        let (exe, args) = generateClusterIDCommand()
                        clusterID = try await ProcessRunner.runChecked(exe, args)
                        try? clusterID.write(toFile: clusterIDPath, atomically: true, encoding: .utf8)
                    }
                    continuation.yield(.stdout("Cluster ID: \(clusterID)"))

                    let (exe, args) = formatCommand(clusterID: clusterID)
                    for try await line in ProcessRunner.lines(exe, args) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Process

    public var spec: ServiceProcessSpec {
        ServiceProcessSpec(
            name: Self.serviceName,
            executable: installation.serverStart,
            arguments: [configPath],
            environment: ["KAFKA_HEAP_OPTS": "-Xmx512M -Xms256M"]
        )
    }

    public var displayCommand: String { spec.commandLine }

    /// Delete everything the broker has stored, including topics and the cluster ID, so the next
    /// start begins from nothing.
    public func resetStorage() throws {
        if FileManager.default.fileExists(atPath: dataDirectory) {
            try FileManager.default.removeItem(atPath: dataDirectory)
        }
        try FileManager.default.createDirectory(atPath: dataDirectory + "/logs", withIntermediateDirectories: true)
    }
}
