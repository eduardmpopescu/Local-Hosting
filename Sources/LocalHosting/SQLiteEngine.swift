import Foundation

/// Reads the output of `sqlite3 -json`: any number of arrays, each a list of rows. A statement that returns
/// no rows prints nothing. Rows keep their columns in order, which a dictionary wouldn't.
enum SQLiteJSON {
    typealias Row = [(column: String, value: String?)]

    static func parse(_ text: String) -> [[Row]] {
        let bytes = Array(text.utf8)
        var i = 0
        var arrays: [[Row]] = []

        func skip() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09, 0x2C].contains(bytes[i]) { i += 1 } }

        func string() -> String {
            let start = i
            i += 1
            while i < bytes.count, bytes[i] != 0x22 {
                i += bytes[i] == 0x5C ? 2 : 1
            }
            i = min(i + 1, bytes.count)
            let raw = Data(bytes[start..<i])
            return (try? JSONDecoder().decode(String.self, from: raw)) ?? String(decoding: raw, as: UTF8.self)
        }

        func value() -> String? {
            if bytes[i] == 0x22 { return string() }
            let start = i
            while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A].contains(bytes[i]) { i += 1 }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            return token == "null" ? nil : token
        }

        skip()
        while i < bytes.count, bytes[i] == 0x5B {
            i += 1
            var rows: [Row] = []
            skip()
            while i < bytes.count, bytes[i] != 0x5D {
                guard bytes[i] == 0x7B else { i += 1; continue }
                i += 1
                var row: Row = []
                skip()
                while i < bytes.count, bytes[i] != 0x7D {
                    let key = string()
                    skip()
                    if i < bytes.count, bytes[i] == 0x3A { i += 1 }
                    skip()
                    guard i < bytes.count else { break }
                    row.append((key, value()))
                    skip()
                }
                i = min(i + 1, bytes.count)
                rows.append(row)
                skip()
            }
            i = min(i + 1, bytes.count)
            arrays.append(rows)
            skip()
        }
        return arrays
    }
}

/// The Browser's view of SQLite databases: each is a file Local Hosting keeps, read through the `sqlite3` that
/// comes with macOS. There is no server, so nothing needs installing or switching on.
@MainActor
struct SQLiteEngine: BrowserEngine {
    /// The SQLite databases that exist.
    let databases: () -> [Database]

    private static let exactCountLimit = 100_000

    let name = "SQLite"
    let symbol = DatabaseEngine.sqlite.symbol
    let vocabulary = BrowserVocabulary()
    var signedInNote: String { "reading each database's file directly" }

    func isInstalled(_ setup: SetupStatus) -> Bool { true }
    func isRunning(_ state: AppState) -> Bool { true }

    private func file(_ database: String) -> URL { Paths.sqliteFile(named: database) }

    /// Runs SQL against a database's file and returns its result sets, and the error that stopped it, if any.
    private func execute(_ sql: String, in database: String, readOnly: Bool = true) async -> (sets: [[SQLiteJSON.Row]], error: String?) {
        let path = file(database).path
        guard FileManager.default.fileExists(atPath: path) else { return ([], "The file \(path) isn't there.") }
        let result = await Shell.run(Paths.sqlite3, ["-bail", "-json"] + (readOnly ? ["-readonly"] : []) + [path], input: sql)
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (SQLiteJSON.parse(result.stdout), result.ok ? nil : (message.isEmpty ? "sqlite3 failed (exit \(result.status))." : message))
    }

    private func texts(_ rows: [SQLiteJSON.Row]) -> [[String?]] { rows.map { $0.map(\.value) } }

    private func quoted(_ item: BrowserItem) -> String { SQLQuote.identifier(item.name) }

    func catalog() async throws -> BrowserCatalog {
        let names = databases().map(\.name)
        var items: [String: [BrowserItem]] = [:]
        for database in names {
            let outcome = await execute("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name;",
                                        in: database)
            items[database] = (outcome.sets.first ?? []).compactMap { row in
                guard row.count == 2, let name = row[0].value else { return nil }
                return BrowserItem(database: database, name: name, isView: row[1].value == "view")
            }
        }
        return BrowserCatalog(databases: names, items: items)
    }

    func exactCounts(for items: [BrowserItem]) async -> [String: Int] {
        var counts: [String: Int] = [:]
        for (database, group) in Dictionary(grouping: items.filter { !$0.isView }, by: \.database) {
            let sql = group.map { "SELECT \(SQLQuote.literal($0.name)) AS n, COUNT(*) AS c FROM \(quoted($0))" }
                .joined(separator: " UNION ALL ") + ";"
            for row in await execute(sql, in: database).sets.first ?? [] where row.count == 2 {
                guard let name = row[0].value, let count = row[1].value.flatMap({ Int($0) }) else { continue }
                counts[BrowserItem(database: database, name: name, isView: false).id] = count
            }
        }
        return counts
    }

    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage {
        let order = sort.map { " ORDER BY \(SQLQuote.identifier($0.column)) \($0.ascending ? "ASC" : "DESC")" } ?? ""
        // The count always prints, the rows only when there are some, and the column list always comes last.
        let outcome = await execute("""
        SELECT COUNT(*) AS c FROM \(quoted(item));
        SELECT * FROM \(quoted(item))\(order) LIMIT \(size) OFFSET \(page * size);
        PRAGMA table_info(\(SQLQuote.literal(item.name)));
        """, in: item.database)
        if let message = outcome.error { throw ShellError(message) }
        let sets = outcome.sets
        let total = sets.first?.first?.first?.value.flatMap { Int($0) } ?? 0
        let info = sets.last ?? []
        let rows = sets.count == 3 ? sets[1] : []
        let columns = rows.first.map { $0.map(\.column) } ?? info.compactMap { $0.first { $0.column == "name" }?.value }
        let types = info.compactMap { $0.first { $0.column == "type" }?.value?.uppercased() }
        let numeric = types.count == columns.count
            ? types.map { type in ["INT", "REAL", "FLOA", "DOUB", "NUM", "DEC"].contains { type.contains($0) } }
            : nil
        return BrowserPage(grid: GridData(columns: columns, rows: texts(rows), numeric: numeric), total: total)
    }

    func structure(of item: BrowserItem) async throws -> [BrowserSection] {
        let name = SQLQuote.literal(item.name)
        let outcome = await execute("""
        SELECT name, type, CASE WHEN "notnull" = 1 THEN 'No' ELSE 'Yes' END, dflt_value, CASE WHEN pk > 0 THEN 'PRI' ELSE '' END
        FROM pragma_table_info(\(name));
        SELECT il.name, group_concat(ii.name, ', ' ORDER BY ii.seqno), CASE il."unique" WHEN 1 THEN 'Yes' ELSE 'No' END
        FROM pragma_index_list(\(name)) il, pragma_index_info(il.name) ii GROUP BY il.name ORDER BY il.name;
        """, in: item.database)
        if let message = outcome.error { throw ShellError(message) }
        return [
            BrowserSection(title: "Columns", symbol: "tablecells",
                           grid: GridData(columns: ["Column", "Type", "Null", "Default", "Key"], rows: texts(outcome.sets.first ?? []))),
            BrowserSection(title: "Indexes", symbol: "bolt.horizontal",
                           grid: GridData(columns: ["Index", "Columns", "Unique"],
                                          rows: outcome.sets.count > 1 ? texts(outcome.sets[1]) : [])),
        ]
    }

    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome {
        // The last statement reports how many rows all the others changed.
        let outcome = await execute(text + "\n;SELECT total_changes() AS \"__changes\";", in: database, readOnly: false)
        var sets = outcome.sets
        var changed = 0
        if let last = sets.last, last.count == 1, last[0].count == 1, last[0][0].column == "__changes" {
            changed = last[0][0].value.flatMap { Int($0) } ?? 0
            sets.removeLast()
        }
        var results = sets.map { rows in
            QueryResult(columns: rows.first.map { $0.map(\.column) } ?? [], rows: Array(texts(rows).prefix(limit)), total: rows.count)
        }
        if results.isEmpty && outcome.error == nil { results = [QueryResult(affected: changed)] }
        return QueryOutcome(results: results, error: outcome.error)
    }

}
