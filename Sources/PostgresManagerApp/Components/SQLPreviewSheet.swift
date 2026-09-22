import PGKit
import SwiftUI

/// Shows exactly what will run before it runs.
///
/// Every privilege change goes through this. The app writes the GRANTs so the user doesn't have
/// to, but it never hides them — and because Postgres makes DDL transactional, the whole script
/// either applies or none of it does.
struct SQLPreviewSheet: View {
    let script: SQLScript
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(script.title).font(.title3.weight(.semibold))
                Text("Runs against **\(script.database)** as a single transaction — if any statement fails, none of it is applied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            if script.isDestructive {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This removes access or drops privileges. Read it through before applying.")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(script.statements) { statement in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statement.rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(statement.sql)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script.rendered, forType: .string)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
    }
}
