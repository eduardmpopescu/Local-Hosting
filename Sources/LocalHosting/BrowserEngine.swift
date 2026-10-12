import Foundation

// What the Browser needs from a database engine, in terms that fit all of them: a database holds
// tables (SQL engines), collections (MongoDB) or keys (Redis), each with rows to page through, a
// structure, and a place to type queries. The Browser never mentions MySQL, only this.

/// One table, view, collection or key inside a database.
struct BrowserItem: Identifiable, Hashable {
    let database: String
    let name: String
    /// PostgreSQL: the schema the table is in.
    var schema: String?
    let isView: Bool
    /// A small tag next to the name besides "view": a Redis key's type.
    var badge: String?
    var rows: Int?
    /// False for very large items, where counting would be slow and the engine's estimate is shown.
    var exact = false
    var id: String { database + "." + (schema.map { $0 + "." } ?? "") + name }

    /// What the list shows: a table outside the default schema keeps its schema in front.
    var title: String {
        guard let schema, schema != "public" else { return name }
        return schema + "." + name
    }

    static func == (a: BrowserItem, b: BrowserItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Every database and what's inside it.
struct BrowserCatalog {
    var databases: [String]
    var items: [String: [BrowserItem]]
}

/// A grid of text cells, as the Browser shows them.
struct GridData {
    var columns: [String]
    var rows: [[String?]]
    /// Which columns hold numbers, when the engine knows.
    var numeric: [Bool]?
}

struct BrowserSort: Equatable {
    var column: String
    var ascending: Bool
}

/// One page of an item's rows and how many it has in all.
struct BrowserPage {
    var grid: GridData
    var total: Int
}

/// A titled part of an item's structure (columns, indexes, …), shown as its own section.
struct BrowserSection {
    var title: String
    var symbol: String
    var grid: GridData
}

/// What running a query returned: every result set, or the error that stopped it.
struct QueryOutcome {
    var results: [QueryResult]
    var error: String?
}

struct QueryResult: Decodable {
    var columns: [String]?
    /// The engine's own names for the columns' types, when it reports them.
    var types: [String]?
    var rows: [[String?]]?
    var total: Int?
    var affected: Int?
}

/// The words the Browser uses for an engine's things.
struct BrowserVocabulary {
    var database = "database"
    var item = "table"
    var items = "tables"
    /// The name of the query tab, and what's typed in it.
    var query = "SQL"
    var queryHint = "Separate statements with semicolons. Changes can't be undone."
    /// Whether a column header can be clicked to sort the rows.
    var sortable = true
}

@MainActor
protocol BrowserEngine {
    var name: String { get }
    var symbol: String { get }
    var vocabulary: BrowserVocabulary { get }
    /// Shown under the page title: who the Browser is signed in as.
    var signedInNote: String { get }

    func isInstalled(_ setup: SetupStatus) -> Bool
    func isRunning(_ state: AppState) -> Bool

    func catalog() async throws -> BrowserCatalog
    /// Exact row counts for items whose catalog figure is only an estimate, keyed by `BrowserItem.id`.
    func exactCounts(for items: [BrowserItem]) async -> [String: Int]
    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage
    func structure(of item: BrowserItem) async throws -> [BrowserSection]
    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome
}
