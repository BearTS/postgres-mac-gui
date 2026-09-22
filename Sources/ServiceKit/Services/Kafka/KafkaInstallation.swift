import Foundation

/// A Kafka distribution found on this machine.
///
/// Kafka's own tooling is a set of shell scripts wrapping a JVM, so everything here is a path to
/// one of those scripts rather than a single binary.
public struct KafkaInstallation: Identifiable, Sendable, Hashable {
    /// Directory holding `kafka-server-start`, `kafka-topics`, and friends.
    public let binDir: String
    public let version: String
    /// The `server.properties` Homebrew ships, used as the starting point for our own config.
    public let packagedConfigPath: String?

    public var id: String { binDir }
    public var displayName: String { "Kafka \(version)" }

    public init(binDir: String, version: String, packagedConfigPath: String?) {
        self.binDir = binDir
        self.version = version
        self.packagedConfigPath = packagedConfigPath
    }

    public var majorVersion: Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    /// Kafka 4 removed ZooKeeper entirely, so a cluster must be formatted for KRaft before it
    /// will start.
    public var requiresKRaft: Bool { majorVersion >= 4 }

    public static let brewFormula = "kafka"
    public static var installCommand: String { "brew install \(brewFormula)" }

    public func tool(_ name: String) -> String { binDir + "/" + name }

    public var serverStart: String { tool("kafka-server-start") }
    public var serverStop: String { tool("kafka-server-stop") }
    public var topics: String { tool("kafka-topics") }
    public var storage: String { tool("kafka-storage") }
    public var consoleConsumer: String { tool("kafka-console-consumer") }
    public var consoleProducer: String { tool("kafka-console-producer") }
    public var consumerGroups: String { tool("kafka-consumer-groups") }
    public var configs: String { tool("kafka-configs") }

    /// Every Kafka command shells out to a JVM.
    ///
    /// `/usr/libexec/java_home` does not see Homebrew's openjdk, because it is keg-only and never
    /// registered with macOS — but Homebrew's Kafka wrappers set `JAVA_HOME` themselves and work
    /// regardless. So a Homebrew JDK counts even though the system tool denies it exists.
    public static func javaIsAvailable(brewPrefix: String = "/opt/homebrew") async -> Bool {
        let brewJDK = "\(brewPrefix)/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin/java"
        if FileManager.default.isExecutableFile(atPath: brewJDK) { return true }
        if let result = try? await ProcessRunner.run("/usr/libexec/java_home", []), result.isSuccess {
            return true
        }
        return false
    }

    public static func discover(brewPrefix: String = "/opt/homebrew") async -> KafkaInstallation? {
        let candidates = [
            "\(brewPrefix)/opt/kafka/bin",
            "\(brewPrefix)/bin",
        ]
        for binDir in candidates {
            guard FileManager.default.isExecutableFile(atPath: binDir + "/kafka-server-start") else { continue }
            let version = await self.version(brewPrefix: brewPrefix, binDir: binDir) ?? "unknown"
            let config = ["\(brewPrefix)/etc/kafka/server.properties"]
                .first { FileManager.default.fileExists(atPath: $0) }
            return KafkaInstallation(binDir: binDir, version: version, packagedConfigPath: config)
        }
        return nil
    }

    /// Kafka's scripts have no `--version` flag, so the version comes from the jar file names —
    /// far cheaper than booting a JVM to ask.
    static func version(brewPrefix: String, binDir: String) async -> String? {
        let libexec = (binDir as NSString).deletingLastPathComponent + "/libexec/libs"
        let fallback = "\(brewPrefix)/opt/kafka/libexec/libs"
        for directory in [libexec, fallback] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            if let version = parseVersion(fromJarNames: entries) { return version }
        }
        return nil
    }

    /// `kafka-clients-4.3.1.jar` -> `4.3.1`
    public static func parseVersion(fromJarNames names: [String]) -> String? {
        for name in names where name.hasPrefix("kafka-clients-") && name.hasSuffix(".jar") {
            let middle = name.dropFirst("kafka-clients-".count).dropLast(".jar".count)
            // Skip sources/javadoc variants and anything that is not a plain version.
            let candidate = String(middle)
            if candidate.allSatisfy({ $0.isNumber || $0 == "." }) { return candidate }
        }
        return nil
    }
}
