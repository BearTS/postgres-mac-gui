import ServiceKit
import SwiftUI

// MARK: - Overview

struct KafkaOverviewView: View {
    @Environment(KafkaModel.self) private var model
    @StateObject private var local = KafkaOverviewState()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.installation == nil {
                    notInstalled
                } else {
                    statusCard
                    if !model.isFormatted { setupCard }
                    configurationCard
                    if !model.setupOutput.isEmpty { outputCard }
                    dangerZone
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Kafka")
        .alert(
            "Kafka",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog("Reset Kafka?", isPresented: $local.confirmReset, titleVisibility: .visible) {
            Button("Stop and erase everything", role: .destructive) { Task { await model.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the broker and permanently deletes every topic and message it holds.")
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kafka is not installed").font(.largeTitle.weight(.semibold))
            Text("Kafka runs on the JVM, so Homebrew installs a JDK alongside it. That makes this a larger download than the other services — a few hundred megabytes.")
                .foregroundStyle(.secondary)
            CommandBlock(command: KafkaInstallation.installCommand)
            Button("Rescan") { Task { await model.bootstrap() } }
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(model.summary.tint).frame(width: 9, height: 9)
                    Text(model.summary.detail).font(.title3.weight(.medium))
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.busyMessage).foregroundStyle(.secondary)
                    }
                }

                if let installation = model.installation {
                    LabeledContent("Version", value: installation.version)
                }
                if let server = model.server {
                    LabeledContent("Bootstrap server", value: server.bootstrapServer).textSelection(.enabled)
                }
                if let pid = model.status.pid {
                    LabeledContent("Process ID", value: String(pid))
                }
                if !model.javaAvailable {
                    Label("No Java runtime found. Kafka cannot start without one.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }

                HStack {
                    if model.status.isAlive {
                        Button("Stop") { Task { await model.stop() } }
                        Button("Restart") { Task { await model.restart() } }
                    } else {
                        Button("Start") { Task { await model.start() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if case .stale = model.status {
                        Button("Clean up crashed process") { Task { await model.clearStalePID() } }
                    }
                }
                .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var setupCard: some View {
        GroupBox("First-time setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kafka 4 runs without ZooKeeper, which means its storage has to be formatted with a cluster ID before the broker will start. Starting Kafka does this automatically, but you can run it on its own here.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Prepare storage") { Task { await model.setUp() } }
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var configurationCard: some View {
        @Bindable var model = model
        return GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Port")
                    TextField("Port", value: $model.port, format: .number.grouping(.never))
                        .frame(width: 80)
                        .disabled(model.status.isAlive)
                }
                if model.status.isAlive {
                    Text("Stop Kafka to change the port.").font(.caption).foregroundStyle(.secondary)
                }
                if let server = model.server {
                    Text("This runs:").font(.caption).foregroundStyle(.secondary)
                    CommandBlock(command: server.displayCommand)
                    LabeledContent("Config file", value: server.configPath).textSelection(.enabled)
                    LabeledContent("Log directory", value: server.dataDirectory + "/logs").textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup output").font(.headline)
            ProcessOutputView(lines: model.setupOutput)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private var dangerZone: some View {
        GroupBox("Reset") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erase this broker").font(.callout.weight(.medium))
                    Text("Stops Kafka and deletes every topic and message.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset…", role: .destructive) { local.confirmReset = true }
                    .disabled(model.isBusy)
            }
            .padding(6)
        }
    }

    @MainActor
    final class KafkaOverviewState: ObservableObject {
        @Published var confirmReset = false
    }
}

// MARK: - Topics and messages

struct KafkaTopicsView: View {
    @Environment(KafkaModel.self) private var model
    @StateObject private var local = KafkaTopicsState()

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.brokerReachable {
                EmptyStateView(
                    symbol: "arrow.left.arrow.right.circle",
                    title: model.installation == nil ? "Kafka is not installed" : "Kafka is not running",
                    message: model.installation == nil
                        ? "Install it from the Overview tab to create topics and browse messages."
                        : "Start the broker to create topics and browse messages.",
                    actionTitle: model.installation == nil ? nil : "Start Kafka",
                    action: model.installation == nil ? nil : { Task { await model.start() } }
                )
            } else {
                HSplitView {
                    topicList
                    messagePane
                }
            }
        }
        .navigationTitle("Kafka Topics")
        .toolbar {
            ToolbarItem {
                Button { local.showCreate = true } label: { Label("New Topic", systemImage: "plus") }
                    .disabled(!model.brokerReachable)
            }
            ToolbarItem {
                Button { Task { await model.refreshTopics() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $local.showCreate) { createTopicSheet }
        .sheet(isPresented: $local.showProduce) { produceSheet }
        .confirmationDialog(
            "Delete topic \(local.pendingDelete ?? "")?",
            isPresented: Binding(get: { local.pendingDelete != nil }, set: { if !$0 { local.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete topic", role: .destructive) {
                if let name = local.pendingDelete {
                    local.pendingDelete = nil
                    Task { await model.deleteTopic(name: name) }
                }
            }
            Button("Cancel", role: .cancel) { local.pendingDelete = nil }
        } message: {
            Text("Every message on the topic is deleted with it.")
        }
    }

    private var topicList: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            List(model.topics, selection: Binding(
                get: { model.selectedTopic?.id },
                set: { id in
                    model.selectedTopic = model.topics.first { $0.id == id }
                    model.messages = []
                    Task { await model.loadMessages() }
                }
            )) { topic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.name)
                    Text("\(topic.partitionCount) partition\(topic.partitionCount == 1 ? "" : "s") · replication \(topic.replicationFactor)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(topic.id)
                .contextMenu {
                    Button("Delete Topic…", role: .destructive) { local.pendingDelete = topic.name }
                }
            }
            Divider()
            Toggle("Show internal topics", isOn: $model.showInternalTopics)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(8)
                .onChange(of: model.showInternalTopics) { _, _ in
                    Task { await model.refreshTopics() }
                }
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
    }

    @ViewBuilder
    private var messagePane: some View {
        @Bindable var model = model
        if let topic = model.selectedTopic {
            VStack(spacing: 0) {
                HStack {
                    Text(topic.name).font(.title3.weight(.medium))
                    Spacer()
                    Picker("", selection: $model.startPosition) {
                        ForEach(KafkaMessageReader.StartPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: model.startPosition) { _, _ in
                        Task { await model.loadMessages() }
                    }
                    Button { Task { await model.loadMessages() } } label: {
                        Label("Load", systemImage: "arrow.down.circle")
                    }
                    Button { local.showProduce = true } label: {
                        Label("Produce", systemImage: "paperplane")
                    }
                }
                .padding(10)

                Divider()

                if model.isLoadingMessages {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Reading from \(topic.name)…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.messages.isEmpty {
                    EmptyStateView(
                        symbol: "tray",
                        title: "No messages",
                        message: "Nothing has been published to this topic yet, or everything in it has aged out of retention."
                    )
                } else {
                    messageList
                }
            }
        } else {
            EmptyStateView(
                symbol: "list.bullet.rectangle",
                title: "Select a topic",
                message: "Messages appear here, with JSON payloads formatted for reading."
            )
        }
    }

    private var messageList: some View {
        VSplitView {
            List(model.messages, selection: Binding(
                get: { local.selectedMessage },
                set: { local.selectedMessage = $0 }
            )) { message in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("p\(message.partition) · \(message.offset)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let key = message.key {
                            Text(key).font(.system(.caption2, design: .monospaced)).foregroundStyle(.blue)
                        }
                    }
                    .frame(width: 110, alignment: .leading)

                    Text(message.summary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)

                    Spacer()
                    if message.isJSON {
                        Text("JSON")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                .tag(message.id)
            }

            detailPane
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected = model.messages.first(where: { $0.id == local.selectedMessage }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Partition \(selected.partition) · offset \(selected.offset)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selected.prettyValue, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                    if let key = selected.key {
                        LabeledContent("Key", value: key)
                    }
                    if !selected.headers.isEmpty {
                        LabeledContent("Headers", value: selected.headers.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    }
                    // Pretty-printed when the payload is JSON, byte-for-byte when it is not.
                    Text(selected.prettyValue)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(minHeight: 140)
        } else {
            Text("Select a message to see its full payload.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    // MARK: Sheets

    private var createTopicSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Topic").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $local.newTopicName)
                Stepper("Partitions: \(local.newPartitions)", value: $local.newPartitions, in: 1...50)
                Text("Replication is fixed at 1: there is only one broker to hold a copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { local.showCreate = false }
                Button("Create") {
                    let name = local.newTopicName
                    let partitions = local.newPartitions
                    local.showCreate = false
                    local.newTopicName = ""
                    Task { await model.createTopic(name: name, partitions: partitions, replicationFactor: 1) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(local.newTopicName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var produceSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Produce a message").font(.title3.weight(.semibold))
            if let topic = model.selectedTopic {
                Text("to \(topic.name)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Key (optional)", text: $local.produceKey)
            Text("Value").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $local.produceValue)
                .font(.system(.body, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Button("Format as JSON") {
                    if let pretty = JSONFormatting.pretty(local.produceValue) {
                        local.produceValue = pretty
                    }
                }
                .disabled(JSONFormatting.pretty(local.produceValue) == nil)
                Spacer()
                Button("Cancel", role: .cancel) { local.showProduce = false }
                Button("Send") {
                    let key = local.produceKey
                    let value = local.produceValue
                    local.showProduce = false
                    Task {
                        await model.send(key: key, value: value)
                        await model.loadMessages()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(local.produceValue.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @MainActor
    final class KafkaTopicsState: ObservableObject {
        @Published var showCreate = false
        @Published var showProduce = false
        @Published var newTopicName = ""
        @Published var newPartitions = 1
        @Published var pendingDelete: String?
        @Published var selectedMessage: UUID?
        @Published var produceKey = ""
        @Published var produceValue = "{\n  \"hello\": \"world\"\n}"
    }
}

// MARK: - Logs

struct KafkaLogsView: View {
    @Environment(KafkaModel.self) private var model
    @StateObject private var local = KafkaLogsState()

    var body: some View {
        Group {
            if local.lines.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "No Kafka output yet",
                    message: "Starting the broker writes its output here. This is where a failed start explains itself."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(local.lines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.isError ? Color.red : line.isWarning ? Color.orange : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: local.lines.count) { _, _ in
                        if let last = local.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kafka Logs")
        .task(id: model.server?.spec.logPath) { await tail() }
    }

    private func tail() async {
        guard let path = model.server?.spec.logPath else { return }
        local.lines = []
        for await line in await local.tailer.tail(path: path) {
            local.lines.append(line)
            if local.lines.count > 4000 { local.lines.removeFirst(1000) }
        }
    }

    @MainActor
    final class KafkaLogsState: ObservableObject {
        @Published var lines: [LogTailer.Line] = []
        let tailer = LogTailer()
    }
}
