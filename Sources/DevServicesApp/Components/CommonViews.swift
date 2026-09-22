import ServiceKit
import SwiftUI

/// Server status shown as a coloured pill.
struct StatusPill: View {
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tint)
                .frame(width: 8, height: 8)
            Text(status.shortDescription)
                .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
    }
}

/// A shell command shown verbatim with a copy button, and optionally a button to run it.
///
/// The app never hides what it does to the system: whatever it is about to run is shown here
/// first, in a form the user could paste into their own terminal instead.
struct CommandBlock: View {
    let command: String
    var runTitle: String?
    var run: (() -> Void)?

    @StateObject private var local = CopyState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    local.copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        local.copied = false
                    }
                } label: {
                    Label(local.copied ? "Copied" : "Copy", systemImage: local.copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }
            if let run, let runTitle {
                Button(runTitle, action: run)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @MainActor
    final class CopyState: ObservableObject {
        @Published var copied = false
    }
}

/// Empty-state placeholder with an optional call to action.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Streams the output of whatever command is currently running.
struct ProcessOutputView: View {
    let lines: [ProcessOutputLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.isError ? Color.orange : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { _, newValue in
                withAnimation { proxy.scrollTo(newValue - 1, anchor: .bottom) }
            }
        }
    }
}

/// Renders a `DynamicResult` as a native table.
struct ResultGridView: View {
    let result: DynamicResult

    var body: some View {
        if result.isEmptyResult {
            Text("Statement completed. No rows returned.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Table(indexedRows) {
                    TableColumnForEach(result.columns) { column in
                        TableColumn(column.name) { row in
                            Text(row.values[safe: column.index].flatMap { $0 } ?? "NULL")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(
                                    row.values[safe: column.index].flatMap { $0 } == nil ? Color.secondary : Color.primary
                                )
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
                    if result.wasTruncated {
                        Text("· showing the first \(result.rowCount); more were returned")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(String(format: "%.0f ms", result.duration * 1000))
                    Button("Copy CSV") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.csv(), forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
        }
    }

    private var indexedRows: [IndexedRow] {
        result.rows.enumerated().map { IndexedRow(id: $0.offset, values: $0.element) }
    }

    struct IndexedRow: Identifiable {
        let id: Int
        let values: [String?]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var shortDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}
