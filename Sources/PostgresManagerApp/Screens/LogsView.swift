import PGKit
import SwiftUI

/// Live tail of the server log, plus a record of every command the app has run.
struct LogsView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = LogsState()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $local.tab) {
                Text("Server Log").tag(LogsState.Tab.server)
                Text("Commands Run").tag(LogsState.Tab.commands)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch local.tab {
            case .server:  serverLog
            case .commands: commandHistory
            }
        }
        .navigationTitle("Logs")
        .task(id: model.controller?.dataDirectory) { await tailLog() }
    }

    @ViewBuilder
    private var serverLog: some View {
        if local.lines.isEmpty {
            EmptyStateView(
                symbol: "doc.text.magnifyingglass",
                title: "No log output yet",
                message: model.controller?.activeLogPath().map { "Watching \($0)" }
                    ?? "The server has not written a log file yet. Starting it will create one."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(local.lines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(colour(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: local.lines.count) { _, _ in
                    if local.followTail, let last = local.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Toggle("Follow", isOn: $local.followTail).toggleStyle(.checkbox)
                    Spacer()
                    if let path = model.controller?.activeLogPath() {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private var commandHistory: some View {
        List(CommandLog.shared.records.reversed()) { record in
            DisclosureGroup {
                Text(record.outputText.isEmpty ? "(no output)" : record.outputText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: symbol(for: record.status))
                        .foregroundStyle(tint(for: record.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.command)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                        Text(record.startedAt.shortDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tailLog() async {
        guard let path = model.controller?.activeLogPath() else { return }
        local.lines = []
        for await line in await local.tailer.tail(path: path) {
            local.lines.append(line)
            if local.lines.count > 5000 { local.lines.removeFirst(1000) }
        }
    }

    private func colour(for line: LogTailer.Line) -> Color {
        if line.isError { return .red }
        if line.isWarning { return .orange }
        return .primary
    }

    private func symbol(for status: CommandRecord.Status) -> String {
        switch status {
        case .running:   return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private func tint(for status: CommandRecord.Status) -> Color {
        switch status {
        case .running:   return .secondary
        case .succeeded: return .green
        case .failed:    return .red
        }
    }

    @MainActor
    final class LogsState: ObservableObject {
        enum Tab { case server, commands }
        @Published var tab: Tab = .server
        @Published var lines: [LogTailer.Line] = []
        @Published var followTail = true
        let tailer = LogTailer()
    }
}
