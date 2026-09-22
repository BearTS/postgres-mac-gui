import Foundation
import Observation
import ServiceKit
import SwiftUI

@MainActor
@Observable
final class KafkaModel {

    // MARK: Configuration

    var installation: KafkaInstallation?
    var javaAvailable = false
    var port = 9092

    // MARK: State

    var status: SupervisedStatus = .notInstalled
    var isFormatted = false
    var brokerReachable = false
    var topics: [KafkaTopic] = []
    var showInternalTopics = false
    var selectedTopic: KafkaTopic?

    var messages: [KafkaMessage] = []
    var isLoadingMessages = false
    var startPosition: KafkaMessageReader.StartPosition = .beginning

    var isBusy = false
    var busyMessage = ""
    var lastError: String?
    var setupOutput: [ProcessOutputLine] = []

    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    var server: KafkaServer? {
        installation.map { KafkaServer(installation: $0, port: port) }
    }

    var admin: KafkaAdmin? {
        guard let installation, let server else { return nil }
        return KafkaAdmin(installation: installation, bootstrapServer: server.bootstrapServer)
    }

    var reader: KafkaMessageReader? {
        server.map { KafkaMessageReader(bootstrapServer: $0.bootstrapServer) }
    }

    var writer: KafkaMessageWriter? {
        server.map { KafkaMessageWriter(bootstrapServer: $0.bootstrapServer) }
    }

    var summary: ServiceSummary {
        ServiceSummary(
            isInstalled: installation != nil,
            isRunning: status.isRunning && brokerReachable,
            detail: detailText
        )
    }

    private var detailText: String {
        guard installation != nil else { return "Not installed" }
        switch status {
        case .running:
            return brokerReachable ? "Running on :\(port)" : "Starting up…"
        case .starting: return "Starting…"
        case .stale:    return "Crashed"
        case .stopped:  return isFormatted ? "Stopped" : "Not set up"
        case .failed(let message): return message
        case .notInstalled: return "Not installed"
        }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        installation = await KafkaInstallation.discover()
        javaAvailable = await KafkaInstallation.javaIsAvailable()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refresh() async {
        guard let server else {
            status = .notInstalled
            return
        }
        status = ProcessSupervisor.shared.status(server.spec)
        isFormatted = server.isFormatted

        guard status.isAlive else {
            brokerReachable = false
            topics = []
            return
        }
        // "Process alive" is not the same as "broker accepting connections"; Kafka takes a few
        // seconds to become useful after start.
        brokerReachable = await admin?.isReachable() ?? false
        if brokerReachable {
            await refreshTopics()
        }
    }

    func refreshTopics() async {
        guard let admin else { return }
        do {
            topics = try await admin.listTopics(includeInternal: showInternalTopics)
        } catch {
            // A broker that is still starting refuses listings; that is not worth an alert.
            if brokerReachable { lastError = error.localizedDescription }
        }
    }

    // MARK: Setup and lifecycle actions

    /// Format the storage directory for KRaft. Kafka 4 will not start without this, and the
    /// error it gives when you skip it is not obvious.
    func setUp() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Preparing Kafka storage"
        setupOutput = []
        defer { isBusy = false; busyMessage = "" }

        let id = CommandLog.shared.begin(kind: .shell, command: "kafka-storage format")
        do {
            for try await line in server.format() {
                setupOutput.append(line)
                CommandLog.shared.append(id, line: line)
            }
            CommandLog.shared.finish(id, exitCode: 0)
        } catch {
            CommandLog.shared.finish(id, error: error)
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func start() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Starting Kafka"
        defer { isBusy = false; busyMessage = "" }

        do {
            if !server.isFormatted {
                await setUp()
            }
            try server.writeConfigFile()
            let id = CommandLog.shared.begin(kind: .shell, command: server.spec.commandLine)
            try await ProcessSupervisor.shared.start(server.spec)

            // Kafka takes noticeably longer than Postgres or Vault to accept connections.
            let ready = await ProcessSupervisor.shared.waitUntilReady(server.spec, timeout: .seconds(60)) { [admin] in
                await admin?.isReachable() ?? false
            }
            CommandLog.shared.finish(id, exitCode: ready ? 0 : 1)
            if !ready {
                lastError = "Kafka did not become ready.\n\n"
                    + (ProcessSupervisor.shared.recentLog(server.spec) ?? "")
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func stop() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Stopping Kafka"
        defer { isBusy = false; busyMessage = "" }
        streamTask?.cancel()
        await ProcessSupervisor.shared.stop(server.spec, gracePeriod: .seconds(20))
        await refresh()
    }

    func restart() async {
        await stop()
        await start()
    }

    /// Stop the broker and delete every topic and message it holds, then re-format.
    func reset() async {
        guard let server else { return }
        isBusy = true
        busyMessage = "Resetting Kafka"
        defer { isBusy = false; busyMessage = "" }

        streamTask?.cancel()
        await ProcessSupervisor.shared.stop(server.spec, gracePeriod: .seconds(20))
        do {
            try server.resetStorage()
            topics = []
            messages = []
            selectedTopic = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func clearStalePID() async {
        guard let server else { return }
        await ProcessSupervisor.shared.clearStalePIDFile(server.spec)
        await refresh()
    }

    // MARK: Topics

    func createTopic(name: String, partitions: Int, replicationFactor: Int) async {
        guard let admin else { return }
        isBusy = true
        busyMessage = "Creating topic"
        defer { isBusy = false; busyMessage = "" }

        let (exe, args) = admin.createTopicCommand(
            name: name, partitions: partitions, replicationFactor: replicationFactor
        )
        let id = CommandLog.shared.begin(kind: .shell, command: CommandLog.describe(exe, args))
        do {
            try await admin.createTopic(name: name, partitions: partitions, replicationFactor: replicationFactor)
            CommandLog.shared.finish(id, exitCode: 0)
        } catch {
            CommandLog.shared.finish(id, error: error)
            lastError = error.localizedDescription
        }
        await refreshTopics()
    }

    func deleteTopic(name: String) async {
        guard let admin else { return }
        isBusy = true
        busyMessage = "Deleting topic"
        defer { isBusy = false; busyMessage = "" }

        let (exe, args) = admin.deleteTopicCommand(name: name)
        let id = CommandLog.shared.begin(kind: .shell, command: CommandLog.describe(exe, args))
        do {
            try await admin.deleteTopic(name: name)
            CommandLog.shared.finish(id, exitCode: 0)
            if selectedTopic?.name == name {
                selectedTopic = nil
                messages = []
            }
        } catch {
            CommandLog.shared.finish(id, error: error)
            lastError = error.localizedDescription
        }
        await refreshTopics()
    }

    // MARK: Messages

    /// Read a page of messages. Deliberately a one-shot read rather than a live tail, so opening
    /// a busy topic cannot flood the UI.
    func loadMessages(limit: Int = 200) async {
        guard let reader, let topic = selectedTopic else { return }
        isLoadingMessages = true
        defer { isLoadingMessages = false }

        do {
            messages = try await reader.readBatch(topic: topic.name, from: startPosition, limit: limit)
        } catch {
            lastError = error.localizedDescription
            messages = []
        }
    }

    func send(key: String?, value: String) async {
        guard let writer, let topic = selectedTopic else { return }
        do {
            try await writer.send(topic: topic.name, key: key?.isEmpty == true ? nil : key, value: value)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
