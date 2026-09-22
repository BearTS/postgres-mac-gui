import PGKit
import SwiftUI

struct TableBrowserView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var local = BrowserState()

    var body: some View {
        @Bindable var model = model

        HSplitView {
            VStack(spacing: 0) {
                Picker("Database", selection: $model.selectedDatabase) {
                    ForEach(model.databases) { database in
                        Text(database.name).tag(Optional(database.name))
                    }
                }
                .labelsHidden()
                .padding(8)

                Divider()

                List(model.tables, selection: Binding(
                    get: { model.selectedTable?.id },
                    set: { id in
                        model.selectedTable = model.tables.first { $0.id == id }
                        Task { await model.refreshTableDetail() }
                    }
                )) { table in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name)
                        Text("\(table.schema) · \(table.formattedSize) · \(rowEstimateText(table))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(table.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

            if let table = model.selectedTable {
                detail(for: table)
            } else {
                EmptyStateView(
                    symbol: "tablecells",
                    title: "Select a table",
                    message: "Columns, indexes and a page of rows appear here."
                )
            }
        }
        .navigationTitle("Tables")
        .task(id: model.selectedDatabase) { await model.refreshTables() }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshTables() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    /// `reltuples` is -1 on a table that has never been analysed; saying "unknown" is honest,
    /// printing "-1 rows" is not.
    private func rowEstimateText(_ table: TableInfo) -> String {
        table.rowEstimate < 0 ? "row count unknown" : "≈\(table.rowEstimate) rows"
    }

    @ViewBuilder
    private func detail(for table: TableInfo) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(table.qualifiedName).font(.title3.weight(.medium))
                    Text(table.kind.label)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    Spacer()
                }
                HStack(spacing: 14) {
                    Text("Owner: \(table.owner)")
                    Text("Total: \(table.formattedSize)")
                    if let exact = local.exactCount {
                        Text("\(exact) rows")
                    } else {
                        Button("Count rows exactly") { countRows(table) }
                            .buttonStyle(.link)
                            .help("Runs SELECT count(*), which scans the whole table.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            Picker("", selection: $local.tab) {
                Text("Columns").tag(BrowserState.Tab.columns)
                Text("Indexes").tag(BrowserState.Tab.indexes)
                Text("Rows").tag(BrowserState.Tab.rows)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider().padding(.top, 8)

            switch local.tab {
            case .columns:
                Table(model.columns) {
                    TableColumn("Name") { column in
                        HStack {
                            Text(column.name)
                            if column.isPrimaryKey {
                                Image(systemName: "key.fill").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Type") { Text($0.type).font(.system(.caption, design: .monospaced)) }
                    TableColumn("Nullable") { Text($0.isNotNull ? "no" : "yes") }
                    TableColumn("Default") { Text($0.defaultExpression ?? "—").font(.system(.caption, design: .monospaced)) }
                }
            case .indexes:
                Table(model.indexes) {
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Unique") { Text($0.isUnique ? "yes" : "no") }
                    TableColumn("Size") { Text(ByteFormat.string($0.sizeBytes)) }
                    TableColumn("Definition") { Text($0.definition).font(.system(.caption, design: .monospaced)) }
                }
            case .rows:
                rowsTab(table)
            }
        }
        .task(id: table.id) {
            local.exactCount = nil
            local.page = 0
            await loadRows(table)
        }
    }

    @ViewBuilder
    private func rowsTab(_ table: TableInfo) -> some View {
        VStack(spacing: 0) {
            if let result = local.rows {
                ResultGridView(result: result)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Previous") {
                    local.page = max(0, local.page - 1)
                    Task { await loadRows(table) }
                }
                .disabled(local.page == 0)
                Text("Rows \(local.page * local.pageSize + 1)–\((local.page + 1) * local.pageSize)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Next") {
                    local.page += 1
                    Task { await loadRows(table) }
                }
                .disabled(local.rows.map { $0.rowCount < local.pageSize } ?? true)
                Spacer()
            }
            .padding(8)
        }
        .task(id: local.tab) { if local.tab == .rows { await loadRows(table) } }
    }

    private func loadRows(_ table: TableInfo) async {
        guard let database = model.selectedDatabase else { return }
        local.rows = try? await model.catalog.rows(
            of: table, in: database, limit: local.pageSize, offset: local.page * local.pageSize
        )
    }

    private func countRows(_ table: TableInfo) {
        guard let database = model.selectedDatabase else { return }
        Task {
            local.exactCount = try? await model.catalog.exactRowCount(of: table, in: database)
        }
    }

    @MainActor
    final class BrowserState: ObservableObject {
        enum Tab { case columns, indexes, rows }
        @Published var tab: Tab = .columns
        @Published var rows: DynamicResult?
        @Published var exactCount: Int64?
        @Published var page = 0
        let pageSize = 200
    }
}
