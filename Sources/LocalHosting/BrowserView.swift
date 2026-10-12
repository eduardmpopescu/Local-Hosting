import SwiftUI

/// Browses every database of one engine as its admin user, so there's nothing to sign in to.
/// All engine-specific work goes through `BrowserEngine`.
@MainActor
final class DatabaseBrowser: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        // The raw values are also what LOCAL_HOSTING_OPEN_TABLE takes.
        case rows = "Rows", structure = "Structure", query = "SQL"
        var id: String { rawValue }
    }

    static let pageSize = 100

    let engine: any BrowserEngine

    @Published private(set) var databases: [String] = []
    @Published private(set) var tables: [String: [BrowserItem]] = [:]
    @Published var expanded: Set<String> = []
    @Published private(set) var database: String?
    @Published private(set) var table: BrowserItem?
    @Published var mode: Mode = .query

    @Published private(set) var grid: GridData?
    @Published private(set) var sections: [BrowserSection] = []
    @Published private(set) var totalRows = 0
    @Published private(set) var page = 0
    @Published private(set) var sort: BrowserSort?

    @Published var query = ""
    @Published private(set) var queryResults: [QueryResult] = []
    @Published private(set) var queryError: String?

    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private var loaded = false

    init(engine: any BrowserEngine) { self.engine = engine }

    // MARK: Catalog

    func reload() async {
        do {
            let catalog = try await engine.catalog()
            error = nil
            databases = catalog.databases
            tables = catalog.items
            await countRows(in: databases)
            if let database, !databases.contains(database) { clearSelection() }
            if let table, !(tables[table.database] ?? []).contains(where: { $0.id == table.id }) { self.table = nil }
            if !loaded, database == nil, let first = databases.first {
                select(database: first)
            }
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The catalog's row figures can be estimates, so ask the engine for exact counts in small groups.
    private func countRows(in shown: [String]) async {
        let candidates = shown.flatMap { tables[$0] ?? [] }
        for start in stride(from: 0, to: candidates.count, by: 40) {
            let chunk = Array(candidates[start..<min(start + 40, candidates.count)])
            let counts = await engine.exactCounts(for: chunk)
            for item in chunk {
                guard let count = counts[item.id],
                      let index = tables[item.database]?.firstIndex(where: { $0.id == item.id }) else { continue }
                tables[item.database]?[index].rows = count
                tables[item.database]?[index].exact = true
            }
        }
    }

    private func clearSelection() {
        database = nil
        table = nil
        grid = nil
    }

    // MARK: Selection

    func select(database name: String) {
        if database != name {
            query = ""
            queryResults = []
            queryError = nil
        }
        database = name
        table = nil
        grid = nil
        mode = .query
        expanded.insert(name)
    }

    func toggle(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }

    func select(_ item: BrowserItem) {
        if database != item.database {
            queryResults = []
            queryError = nil
        }
        database = item.database
        table = item
        expanded.insert(item.database)
        page = 0
        sort = nil
        if mode == .query { mode = .rows }
        Task { await load() }
    }

    /// Reloads the databases and tables, and the rows or structure that are open.
    func refresh() async {
        await reload()
        if table != nil, mode != .query { await load() }
    }

    func modeChanged() {
        Task { await load() }
    }

    // MARK: Rows and structure

    func load() async {
        guard let table else { return }
        loading = true
        defer { loading = false }
        do {
            switch mode {
            case .rows:
                let result = try await engine.page(of: table, sort: sort, page: page, size: Self.pageSize)
                error = nil
                totalRows = result.total
                if let index = tables[table.database]?.firstIndex(where: { $0.id == table.id }) {
                    tables[table.database]?[index].rows = totalRows
                    tables[table.database]?[index].exact = true
                }
                grid = result.grid
            case .structure:
                sections = try await engine.structure(of: table)
                error = nil
            case .query:
                break
            }
        } catch {
            self.error = error.localizedDescription
            if mode == .rows { grid = nil }
        }
    }

    func sortBy(_ column: String) {
        if sort?.column == column {
            sort?.ascending.toggle()
        } else {
            sort = BrowserSort(column: column, ascending: true)
        }
        page = 0
        Task { await load() }
    }

    var pageCount: Int { max(1, Int((Double(totalRows) / Double(Self.pageSize)).rounded(.up))) }

    func goToPage(_ newPage: Int) {
        page = min(max(0, newPage), pageCount - 1)
        Task { await load() }
    }

    // MARK: Queries

    func runQuery() async {
        guard let database, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let outcome = try await engine.run(query, in: database, limit: 500)
            queryResults = outcome.results
            queryError = outcome.error
        } catch {
            queryResults = []
            queryError = error.localizedDescription
        }
        // The statements may have created or dropped tables.
        await reload()
    }
}

// MARK: - Page

/// One browser per database engine, made when it's first needed, so each keeps what it had open.
@MainActor
final class BrowserHub: ObservableObject {
    private var browsers: [DatabaseEngine: DatabaseBrowser] = [:]

    func browser(for engine: DatabaseEngine, state: AppState) -> DatabaseBrowser {
        if let existing = browsers[engine] { return existing }
        let browser = DatabaseBrowser(engine: Self.makeEngine(engine, state: state))
        browsers[engine] = browser
        return browser
    }

    private static func makeEngine(_ engine: DatabaseEngine, state: AppState) -> any BrowserEngine {
        // The engines that can't list their databases themselves are told which ones Local Hosting made.
        let databases = { [weak state] in state?.config.databases.filter { $0.engine == engine } ?? [] }
        switch engine {
        case .mysql: return MySQLEngine()
        case .postgresql: return PostgresEngine()
        case .mongodb: return MongoEngine(databases: databases)
        case .redis: return RedisEngine(databases: databases)
        case .sqlite: return SQLiteEngine(databases: databases)
        }
    }
}

struct BrowserView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var hub = BrowserHub()
    @AppStorage("browserEngine") private var storedEngine = DatabaseEngine.mysql.rawValue

    /// The software that's installed, and so can be browsed.
    private var available: [DatabaseEngine] { DatabaseEngine.allCases.filter { state.setup.isInstalled($0) } }

    private var engine: DatabaseEngine {
        let stored = DatabaseEngine(rawValue: storedEngine) ?? .mysql
        return available.contains(stored) || available.isEmpty ? stored : available[0]
    }

    var body: some View {
        BrowserScreen(browser: hub.browser(for: engine, state: state), engines: available, selection: Binding(
            get: { engine },
            set: { storedEngine = $0.rawValue }
        ))
        .id(engine)
        .onChange(of: state.browseRequest, initial: true) { _, request in
            guard let request, let db = state.config.databases.first(where: { $0.name == request }) else { return }
            storedEngine = db.engine.rawValue
            hub.browser(for: db.engine, state: state).select(database: request)
            state.browseRequest = nil
        }
    }
}

private struct BrowserScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var browser: DatabaseBrowser
    let engines: [DatabaseEngine]
    @Binding var selection: DatabaseEngine

    private var engine: any BrowserEngine { browser.engine }
    private var running: Bool { engine.isRunning(state) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Browser", subtitle: "Browse and query the \(engine.vocabulary.items) in every \(engine.vocabulary.database), \(engine.signedInNote).") {
                HStack(spacing: 10) {
                    if engines.count > 1 {
                        OptionMenu(selection: $selection, options: engines.map { .init(value: $0, title: $0.name, symbol: $0.symbol) })
                    }
                    ShortcutButton(symbol: "arrow.clockwise", shortcut: "⌘R",
                                   help: "Reload databases, \(engine.vocabulary.items) and what's open (⌘R)") {
                        Task { await browser.refresh() }
                    }
                    .keyboardShortcut("r")
                    .disabled(!running)
                }
            }

            Group {
                if !engine.isInstalled(state.setup) {
                    EmptyState(symbol: engine.symbol, title: "\(engine.name) isn't installed",
                               message: "Install it in Settings, then come back to browse your databases.")
                } else if !running {
                    EmptyState(symbol: "moon.zzz", title: "All \(engine.name) databases are off",
                               message: "Switch a database on in Databases, and its \(engine.vocabulary.items) show up here.")
                } else if let error = browser.error, browser.databases.isEmpty {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't read your databases", message: error,
                               actionTitle: "Try again") { Task { await browser.reload() } }
                } else {
                    HStack(spacing: 0) {
                        CatalogList(browser: browser)
                            .frame(width: 236)
                        Divider()
                        DetailPane(browser: browser)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In a rounded container inset from the page, like the Console's.
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
        }
        .task(id: running) {
            guard running else { return }
            await browser.reload()
            openTestTable()
        }
        .onChange(of: state.config.databases.count) { _, _ in
            Task { await browser.reload() }
        }
    }

    /// Screenshot runs only: opens the table named in LOCAL_HOSTING_OPEN_TABLE.
    private func openTestTable() {
        guard let spec = Paths.testTable, !spec.isEmpty else { return }
        let parts = spec.split(separator: ":")
        let names = parts[0].split(separator: ".").map(String.init)
        guard names.count == 2, let table = browser.tables[names[0]]?.first(where: { $0.name == names[1] }) else { return }
        browser.select(table)
        if parts.count > 1, let mode = DatabaseBrowser.Mode(rawValue: String(parts[1])) {
            browser.mode = mode
            browser.modeChanged()
        }
    }
}

// MARK: - Databases and tables

private struct CatalogList: View {
    @ObservedObject var browser: DatabaseBrowser

    /// Lines a table's name up under its database's name, after the database icon.
    private static let nameIndent: CGFloat = 23

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if browser.databases.isEmpty {
                        Text("No \(browser.engine.vocabulary.database)s yet. Create one in Databases.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(browser.databases, id: \.self) { db in
                        let items = browser.tables[db] ?? []
                        let expanded = browser.expanded.contains(db)
                        CatalogRow(title: db,
                                   symbol: browser.engine.symbol,
                                   detail: items.isEmpty ? nil : String(items.count),
                                   selected: browser.database == db && browser.table == nil,
                                   // A database with nothing in it has nothing to open.
                                   expanded: items.isEmpty ? nil : expanded,
                                   toggle: { browser.toggle(db) }) {
                            browser.select(database: db)
                        }
                        if expanded {
                            ForEach(items) { table in
                                CatalogRow(title: table.title, badge: table.isView ? "view" : table.badge,
                                           detail: table.isView ? nil : table.rows.map { ($0 == 0 || table.exact ? "" : "~") + $0.formatted() },
                                           selected: browser.table == table, indent: Self.nameIndent) {
                                    browser.select(table)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(Color.primary.opacity(0.02))
    }
}

private struct CatalogRow: View {
    let title: String
    /// The engine's icon, shown in front of a database's name.
    var symbol: String?
    /// A small tag after the name: "view", or a Redis key's type.
    var badge: String?
    var detail: String?
    var selected = false
    /// Nil when there's nothing to open or close, which leaves out the chevron.
    var expanded: Bool?
    var indent: CGFloat = 0
    var toggle: (() -> Void)?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? Theme.accent : Color.secondary)
                            .frame(width: 16)
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(selected ? Theme.accent : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if let detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let expanded, let toggle {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse \(title)" : "Expand \(title)")
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: expanded)
    }
}

// MARK: - Rows, structure and SQL

private struct DetailPane: View {
    @ObservedObject var browser: DatabaseBrowser

    private var modes: [DatabaseBrowser.Mode] {
        browser.table == nil ? [.query] : DatabaseBrowser.Mode.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            if let database = browser.database {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(database)
                            .foregroundStyle(browser.table == nil ? .primary : .secondary)
                        if let table = browser.table {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(table.title)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    if browser.loading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if modes.count > 1 {
                        TabSwitcher(selection: $browser.mode, options: [
                            .init(value: .rows, title: "Rows", symbol: "tablecells"),
                            .init(value: .structure, title: "Structure", symbol: "list.bullet.indent"),
                            .init(value: .query, title: browser.engine.vocabulary.query, symbol: "chevron.left.forwardslash.chevron.right"),
                        ])
                        .onChange(of: browser.mode) { _, _ in browser.modeChanged() }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)

                Divider()

                switch browser.mode {
                case .rows: RowsView(browser: browser)
                case .structure: StructureView(browser: browser)
                case .query: QueryConsole(browser: browser)
                }
            } else {
                EmptyState(symbol: "tablecells", title: "Choose a database",
                           message: "Pick a \(browser.engine.vocabulary.database) or \(browser.engine.vocabulary.item) on the left to see its rows, structure, or run \(browser.engine.vocabulary.query).")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RowsView: View {
    @ObservedObject var browser: DatabaseBrowser

    var body: some View {
        VStack(spacing: 0) {
            if let error = browser.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let grid = browser.grid {
                let onSort: ((String) -> Void)? = browser.engine.vocabulary.sortable ? { browser.sortBy($0) } : nil
                DataGrid(columns: grid.columns, rows: grid.rows, numericColumns: grid.numeric,
                         firstColumnTrailing: true, sort: browser.sort, onSort: onSort)
                    // A new page, or a new order, starts from its first row instead of keeping the scroll position
                    // the last one ended at.
                    .id("\(browser.page)|\(browser.sort?.column ?? "")|\(browser.sort?.ascending ?? true)")
                Divider()
                HStack {
                    let first = browser.page * DatabaseBrowser.pageSize
                    Text(browser.totalRows == 0 ? "No rows"
                         : "Rows \((first + 1).formatted())–\((first + grid.rows.count).formatted()) of \(browser.totalRows.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { browser.goToPage(browser.page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(browser.page == 0)
                        .help("Previous page")
                        .accessibilityLabel("Previous page")
                    Text("\(browser.page + 1) of \(browser.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { browser.goToPage(browser.page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(browser.page >= browser.pageCount - 1)
                        .help("Next page")
                        .accessibilityLabel("Next page")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .frame(height: 36)
            } else {
                Spacer()
            }
        }
    }
}

/// The sections of an item's structure (columns and indexes for a table), each with its own header bar. Side by
/// side when the pane is wide enough, the first with the larger share, each filling the full height and
/// continuing with empty rows, so neither just stops. When it isn't wide enough they stack, with nothing
/// between them, and only the last continues with empty rows. Either way it scrolls when there's more than fits.
private struct StructureView: View {
    @ObservedObject var browser: DatabaseBrowser

    private static let sectionChrome: CGFloat = 42 // header bar and its hairlines
    private static let columnTitles: CGFloat = 30
    private static let rowHeight: CGFloat = 28
    /// Below this, two grids side by side would be too cramped to read.
    private static let sideBySideWidth: CGFloat = 720

    var body: some View {
        GeometryReader { geometry in
            let sections = browser.sections
            if sections.count > 1 && geometry.size.width >= Self.sideBySideWidth {
                sideBySide(sections, width: geometry.size.width)
            } else {
                stacked(sections, in: geometry.size)
            }
        }
    }

    private func sideBySide(_ sections: [BrowserSection], width: CGFloat) -> some View {
        // The pane is always shared out equally, whatever is in each side. A side with more than fits scrolls
        // sideways on its own.
        let each = (width - CGFloat(sections.count - 1)) / CGFloat(sections.count)
        return HStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                StructureSection(title: section.title, symbol: section.symbol, count: section.grid.rows.count, topDivider: false) {
                    DataGrid(columns: section.grid.columns, rows: section.grid.rows)
                }
                .frame(width: each, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func stacked(_ sections: [BrowserSection], in size: CGSize) -> some View {
        // What the sections before the last one take up.
        let above = sections.dropLast().enumerated().reduce(CGFloat(0)) { total, entry in
            total + (entry.offset == 0 ? Self.sectionChrome - 1 : Self.sectionChrome)
                + Self.columnTitles + CGFloat(entry.element.grid.rows.count) * Self.rowHeight
        }
        let lastChrome = sections.count > 1 ? Self.sectionChrome : Self.sectionChrome - 1
        let fill = max(0, size.height - above - lastChrome)
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    let last = index == sections.count - 1
                    StructureSection(title: section.title, symbol: section.symbol, count: section.grid.rows.count,
                                     topDivider: index > 0) {
                        DataGrid(columns: section.grid.columns, rows: section.grid.rows, scrolls: false,
                                 fillHeight: last ? fill : 0, fillWidth: size.width)
                    }
                }
            }
            .frame(minWidth: size.width, alignment: .leading)
            .background(NoOverscroll())
        }
    }
}

private struct StructureSection<Content: View>: View {
    let title: String
    let symbol: String
    let count: Int
    /// Off for the first section, which already sits under the toolbar's divider.
    var topDivider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if topDivider { Divider() }
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.primary.opacity(0.035))
            Divider()
            content
        }
    }
}

private struct QueryConsole: View {
    @ObservedObject var browser: DatabaseBrowser

    private var lastGrid: QueryResult? { browser.queryResults.last { $0.columns != nil } }
    private var hasOutput: Bool { !browser.queryResults.isEmpty || browser.queryError != nil }

    private var summary: String {
        browser.queryResults.map { result in
            if let total = result.total {
                return total == 1 ? "1 row" : "\(total.formatted()) rows" + (total > 500 ? " (showing 500)" : "")
            }
            let affected = result.affected ?? 0
            return affected == 1 ? "1 row changed" : "\(affected.formatted()) rows changed"
        }
        .joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $browser.query)
                    .font(Theme.data)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if browser.query.isEmpty {
                    Text("Type a query here…")
                        .font(Theme.data)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)

            // The Run strip divides the query from its results.
            Divider()
            HStack(spacing: 12) {
                Text(browser.queryResults.isEmpty ? browser.engine.vocabulary.queryHint : summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await browser.runQuery() }
                } label: {
                    Label("Run", systemImage: "play.fill").labelStyle(ButtonLabelStyle())
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(browser.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || browser.loading)
                .help("Run (⌘↩)")
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Color.primary.opacity(0.025))
            Divider()

            if let error = browser.queryError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.danger)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let grid = lastGrid, let columns = grid.columns, let rows = grid.rows, !rows.isEmpty {
                DataGrid(columns: columns, rows: rows)
            } else if !hasOutput {
                EmptyState(symbol: "tablecells", title: "Results appear here",
                           message: "Run a query and the rows it returns show up in this space.")
            } else {
                Spacer()
            }
        }
    }
}

// MARK: - Grid

/// A spreadsheet-like grid. The header row stays pinned at the top and columns follow their
/// content; an empty filler takes any leftover width. When the rows don't fill the space,
/// empty striped rows do (like Finder), and the grid doesn't scroll or bounce.
struct DataGrid: View {
    let columns: [String]
    let rows: [[String?]]
    /// Which columns hold numbers (right-aligned). Guessed from the values when not given.
    var numericColumns: [Bool]?
    /// Right-align the first column, header and values (the Browser's Rows view).
    var firstColumnTrailing = false
    var sort: BrowserSort?
    var onSort: ((String) -> Void)?
    /// False when the grid sits inside another scroll view (it then takes its full height).
    var scrolls = true
    /// For a grid that doesn't scroll: the height to fill, continuing with empty rows.
    var fillHeight: CGFloat?
    /// For a grid that doesn't scroll: the width to fill.
    var fillWidth: CGFloat?

    private var naturalHeight: CGFloat { Self.headerHeight + CGFloat(rows.count) * Self.rowHeight }

    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 30

    private var naturalWidths: [CGFloat] { Self.naturalWidths(columns: columns, rows: rows, sortable: onSort != nil) }

    /// How wide each column wants to be: as wide as its longest value, within limits.
    static func naturalWidths(columns: [String], rows: [[String?]], sortable: Bool = false) -> [CGFloat] {
        columns.indices.map { c in
            let longest = rows.prefix(80).reduce(columns[c].count + (sortable ? 2 : 0)) { result, row in
                max(result, min((c < row.count ? row[c] ?? "NULL" : "").count, 46))
            }
            return min(max(CGFloat(longest) * 7.3 + 24, 64), 360)
        }
    }

    private var trailing: [Bool] {
        let numeric = numericColumns ?? columns.indices.map { c in
            let values = rows.prefix(80).compactMap { c < $0.count ? $0[c] : nil }
            return !values.isEmpty && values.allSatisfy { $0.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil }
        }
        return numeric.enumerated().map { index, isNumber in isNumber || (firstColumnTrailing && index == 0) }
    }

    var body: some View {
        if scrolls {
            GeometryReader { geometry in
                let widths = naturalWidths
                let filler = max(0, geometry.size.width - widths.reduce(0, +))
                let fits = naturalHeight <= geometry.size.height
                let blankRows = fits ? Self.blankRows(toFill: geometry.size.height, after: rows.count) : 0
                ScrollView([.horizontal, .vertical]) {
                    table(widths: widths, filler: filler, blankRows: blankRows)
                        // A different table starts from fresh rows rather than reusing the last one's.
                        .id(columns)
                        .frame(minWidth: geometry.size.width, alignment: .topLeading)
                        // Rows that fit take exactly the visible height, so there's nothing to scroll.
                        .frame(height: fits ? geometry.size.height : nil, alignment: .top)
                        .clipped()
                        .background(NoOverscroll())
                }
            }
        } else {
            let widths = naturalWidths
            let filler = max(0, (fillWidth ?? 0) - widths.reduce(0, +))
            let height = max(naturalHeight, fillHeight ?? 0)
            // Small grids inside another scroll view: a plain list, nothing lazy or pinned.
            VStack(alignment: .leading, spacing: 0) {
                header(widths, filler, trailing)
                ForEach(rows.indices, id: \.self) { index in
                    GridRowView(values: rows[index], widths: widths, filler: filler, trailing: trailing,
                                striped: !index.isMultiple(of: 2))
                }
                let blanks = Self.blankRows(toFill: fillHeight ?? 0, after: rows.count)
                ForEach(rows.count..<(rows.count + blanks), id: \.self) { index in
                    BlankGridRow(widths: widths, filler: filler, striped: !index.isMultiple(of: 2))
                }
            }
            .id(columns)
            .frame(height: height, alignment: .top)
            .clipped()
        }
    }

    private static func blankRows(toFill height: CGFloat, after rowCount: Int) -> Int {
        max(0, Int(((height - headerHeight) / rowHeight).rounded(.up)) - rowCount)
    }

    private func table(widths: [CGFloat], filler: CGFloat, blankRows: Int) -> some View {
        let trailing = self.trailing
        return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(rows.indices, id: \.self) { index in
                    GridRowView(values: rows[index], widths: widths, filler: filler, trailing: trailing,
                                striped: !index.isMultiple(of: 2))
                }
                // Numbered after the data rows so the two lists never share an identity.
                ForEach(rows.count..<(rows.count + blankRows), id: \.self) { index in
                    BlankGridRow(widths: widths, filler: filler, striped: !index.isMultiple(of: 2))
                }
            } header: {
                header(widths, filler, trailing)
            }
        }
    }

    private func header(_ widths: [CGFloat], _ filler: CGFloat, _ trailing: [Bool]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { c in
                let name = columns[c]
                Group {
                    if let onSort {
                        Button { onSort(name) } label: {
                            HStack(spacing: 4) {
                                Text(name).lineLimit(1)
                                if sort?.column == name {
                                    Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Sort by \(name)")
                    } else {
                        Text(name).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(sort?.column == name ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(width: widths[c], height: Self.headerHeight, alignment: trailing[c] ? .trailing : .leading)
                .overlay(alignment: .trailing) {
                    if c < columns.count - 1 || filler > 0 { Rectangle().fill(Theme.hairline).frame(width: 1) }
                }
            }
            Color.clear.frame(width: filler, height: Self.headerHeight)
        }
        .background(Theme.canvas)
        .background(Color.primary.opacity(0.04))
        .compositingGroup()
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct GridRowView: View {
    let values: [String?]
    let widths: [CGFloat]
    let filler: CGFloat
    let trailing: [Bool]
    let striped: Bool
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(widths.indices, id: \.self) { c in
                cell(c < values.count ? values[c] : nil, width: widths[c], trailing: trailing[c])
                    .overlay(alignment: .trailing) {
                        if c < widths.count - 1 || filler > 0 { Rectangle().fill(Theme.hairline.opacity(0.5)).frame(width: 1) }
                    }
            }
            Color.clear.frame(width: filler, height: 28)
        }
        .background(hovering ? Theme.accent.opacity(0.08) : striped ? Color.primary.opacity(0.025) : Color.clear)
        .onHover { hovering = $0 }
    }

    private func cell(_ value: String?, width: CGFloat, trailing: Bool) -> some View {
        Group {
            if let value {
                Text(value.count > 300 ? String(value.prefix(300)) + "…" : value)
                    .foregroundStyle(.primary)
            } else {
                Text("NULL").italic().foregroundStyle(.tertiary)
            }
        }
        .font(Theme.data)
        .lineLimit(1)
        .truncationMode(.tail)
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .frame(width: width, height: 28, alignment: trailing ? .trailing : .leading)
        .help(value.map { String($0.prefix(1000)) } ?? "NULL")
    }
}

private struct BlankGridRow: View {
    let widths: [CGFloat]
    let filler: CGFloat
    let striped: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(widths.indices, id: \.self) { c in
                Color.clear
                    .frame(width: widths[c], height: 28)
                    .overlay(alignment: .trailing) {
                        if c < widths.count - 1 || filler > 0 { Rectangle().fill(Theme.hairline.opacity(0.5)).frame(width: 1) }
                    }
            }
            Color.clear.frame(width: filler, height: 28)
        }
        .background(striped ? Color.primary.opacity(0.025) : Color.clear)
        .accessibilityHidden(true)
    }
}

/// Keeps the scroll view it's placed in from ever moving past its content: the bounce is
/// switched off, and any movement beyond an edge (a hard flick, momentum) is clamped back
/// before it's drawn.
private struct NoOverscroll: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.disableBounce() }

    final class Probe: NSView {
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var clamping = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let found = enclosingScrollView, found !== scrollView else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            scrollView = found
            found.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: found.contentView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clamp() }
            })
            disableBounce()
        }

        /// No bounce, and classic scrollbars that stay visible whenever the content is bigger
        /// than the view (rather than only while scrolling).
        func disableBounce() {
            guard let scrollView else { return }
            if scrollView.verticalScrollElasticity != .none { scrollView.verticalScrollElasticity = .none }
            if scrollView.horizontalScrollElasticity != .none { scrollView.horizontalScrollElasticity = .none }
            if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        }

        private func clamp() {
            guard !clamping, let scrollView, let document = scrollView.documentView else { return }
            disableBounce()
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            let minX = -insets.left, minY = -insets.top
            let maxX = max(minX, document.frame.width - clip.bounds.width + insets.right)
            let maxY = max(minY, document.frame.height - clip.bounds.height + insets.bottom)
            let origin = clip.bounds.origin
            let clamped = NSPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
            guard clamped != origin else { return }
            clamping = true
            clip.setBoundsOrigin(clamped)
            scrollView.reflectScrolledClipView(clip)
            clamping = false
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
