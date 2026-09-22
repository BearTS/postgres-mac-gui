import PGKit
import SwiftUI

struct SQLEditorView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = EditorState()

    var body: some View {
        @Bindable var model = model

        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Database", selection: $model.selectedDatabase) {
                        ForEach(model.databases) { database in
                            Text(database.name).tag(Optional(database.name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()

                    Button {
                        run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(local.isRunning || local.text.isEmpty)
                    .help("Run every statement (⌘↩)")
                }
                .padding(8)

                Divider()

                TextEditor(text: $local.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
            }

            results
        }
        .navigationTitle("SQL")
    }

    @ViewBuilder
    private var results: some View {
        if local.outcomes.isEmpty {
            EmptyStateView(
                symbol: "terminal",
                title: "No results yet",
                message: "Write SQL above and press ⌘↩. Multiple statements separated by semicolons run in order."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(local.outcomes) { outcome in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                                Text(outcome.sql)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                                Spacer()
                                Text(String(format: "%.0f ms", outcome.duration * 1000))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let message = outcome.errorMessage {
                                Text(message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            } else if let result = outcome.result {
                                ResultGridView(result: result)
                                    .frame(minHeight: 160, maxHeight: 420)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func run() {
        guard let database = model.selectedDatabase else {
            model.lastError = "Choose a database to run against."
            return
        }
        local.isRunning = true
        Task {
            local.outcomes = await model.queries.run(local.text, database: database)
            local.isRunning = false
        }
    }

    @MainActor
    final class EditorState: ObservableObject {
        @Published var text = "SELECT version();"
        @Published var outcomes: [QueryService.StatementOutcome] = []
        @Published var isRunning = false
    }
}
