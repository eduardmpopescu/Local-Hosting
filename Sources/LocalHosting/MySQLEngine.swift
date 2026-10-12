import Foundation

/// The Browser's view of the private MySQL instance: everything MySQL-specific it asks for lives here.
@MainActor
struct MySQLEngine: BrowserEngine {
    /// Items up to this size are counted exactly; bigger ones show MySQL's estimate.
    private static let exactCountLimit = 100_000
    private static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]
    private static let numericTypes: Set<String> = ["tinyint", "smallint", "mediumint", "int", "integer", "bigint",
                                                    "decimal", "numeric", "float", "double", "real", "bit", "year"]

    let name = "MySQL"
    let symbol = "cylinder.split.1x2"
    let vocabulary = BrowserVocabulary()
    var signedInNote: String { "signed in as \(MySQL.adminUser)" }

    func isInstalled(_ setup: SetupStatus) -> Bool { setup.mysql }
    func isRunning(_ state: AppState) -> Bool { state.isRunning(.mysql) }

    func catalog() async throws -> BrowserCatalog {
        // MySQL caches table statistics for a day by default; ask for fresh ones.
        let response = try await MySQL.query("""
        SET SESSION information_schema_stats_expiry = 0;
        SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME;
        SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES ORDER BY TABLE_SCHEMA, TABLE_NAME;
        """, limit: 100_000)
        if let message = response.error { throw ShellError(message) }
        let sets = response.results.filter { $0.columns != nil }
        guard sets.count == 2 else { throw ShellError("Couldn't read the list of databases from MySQL.") }
        let names = (sets[0].rows ?? []).compactMap { $0.first ?? nil }
        var grouped: [String: [BrowserItem]] = [:]
        for row in sets[1].rows ?? [] where row.count == 4 {
            guard let db = row[0], let name = row[1] else { continue }
            grouped[db, default: []].append(BrowserItem(database: db, name: name, isView: row[2] == "VIEW",
                                                        rows: row[3].flatMap { Int($0) }))
        }
        return BrowserCatalog(databases: names.filter { !Self.systemDatabases.contains($0) }, items: grouped)
    }

    /// MySQL's row figures are estimates (a table with one row can show 0), so count the rows
    /// of every table that isn't huge.
    func exactCounts(for items: [BrowserItem]) async -> [String: Int] {
        let candidates = items.filter { !$0.isView && ($0.rows ?? 0) < Self.exactCountLimit }
        guard !candidates.isEmpty else { return [:] }
        let sql = candidates.map { item in
            "SELECT '\(MySQL.sqlEscape(item.database))', '\(MySQL.sqlEscape(item.name))', COUNT(*) FROM " + qualified(item)
        }.joined(separator: " UNION ALL ") + ";"
        guard let response = try? await MySQL.query(sql, limit: 1_000), response.error == nil,
              let rows = response.results.first?.rows else { return [:] }
        var counts: [String: Int] = [:]
        for row in rows where row.count == 3 {
            guard let db = row[0], let name = row[1], let count = row[2].flatMap({ Int($0) }) else { continue }
            counts[db + "." + name] = count
        }
        return counts
    }

    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage {
        let from = qualified(item)
        let order = sort.map { " ORDER BY \(MySQL.quoteIdentifier($0.column)) \($0.ascending ? "ASC" : "DESC")" } ?? ""
        let db = MySQL.sqlEscape(item.database), name = MySQL.sqlEscape(item.name)
        let response = try await MySQL.query("""
        SELECT COUNT(*) FROM \(from);
        SELECT * FROM \(from)\(order) LIMIT \(size) OFFSET \(page * size);
        SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '\(db)' AND TABLE_NAME = '\(name)' ORDER BY ORDINAL_POSITION;
        """, limit: 10_000)
        if let message = response.error { throw ShellError(message) }
        let total = Int(response.results.first?.rows?.first?.first.flatMap { $0 } ?? "0") ?? 0
        let rows = response.results.count > 1 ? response.results[1] : QueryResult()
        let types = response.results.count > 2 ? (response.results[2].rows ?? []).map { $0.first.flatMap { $0 } ?? "" } : []
        let columns = rows.columns ?? []
        let grid = GridData(columns: columns, rows: Array((rows.rows ?? []).prefix(size)),
                            numeric: types.count == columns.count ? types.map { Self.numericTypes.contains($0.lowercased()) } : nil)
        return BrowserPage(grid: grid, total: total)
    }

    func structure(of item: BrowserItem) async throws -> [BrowserSection] {
        let db = MySQL.sqlEscape(item.database), name = MySQL.sqlEscape(item.name)
        let response = try await MySQL.query("""
        SELECT COLUMN_NAME, COLUMN_TYPE, IF(IS_NULLABLE = 'YES', 'Yes', 'No'), COLUMN_KEY, COLUMN_DEFAULT, EXTRA
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '\(db)' AND TABLE_NAME = '\(name)' ORDER BY ORDINAL_POSITION;
        SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', '), IF(MAX(NON_UNIQUE) = 0, 'Yes', 'No')
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = '\(db)' AND TABLE_NAME = '\(name)' GROUP BY INDEX_NAME ORDER BY INDEX_NAME;
        """, limit: 10_000)
        if let message = response.error { throw ShellError(message) }
        return [
            BrowserSection(title: "Columns", symbol: "tablecells",
                           grid: GridData(columns: ["Column", "Type", "Null", "Key", "Default", "Extra"],
                                          rows: response.results.first?.rows ?? [])),
            BrowserSection(title: "Indexes", symbol: "bolt.horizontal",
                           grid: GridData(columns: ["Index", "Columns", "Unique"],
                                          rows: response.results.count > 1 ? response.results[1].rows ?? [] : [])),
        ]
    }

    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome {
        let response = try await MySQL.query(text, database: database, limit: limit)
        return QueryOutcome(results: response.results, error: response.error)
    }


    private func qualified(_ item: BrowserItem) -> String {
        MySQL.quoteIdentifier(item.database) + "." + MySQL.quoteIdentifier(item.name)
    }
}
