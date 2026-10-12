import Foundation

/// The Browser's view of the private MongoDB server, through `mongosh`. A database holds collections, and a
/// collection's items are documents, shown as rows with a column for each field. The query tab takes mongosh
/// expressions such as `db.users.find({})`, separated by semicolons.
@MainActor
struct MongoEngine: BrowserEngine {
    private static let systemDatabases: Set<String> = ["admin", "config", "local"]

    /// The MongoDB databases that exist. A database has nothing on the server until something is stored in it,
    /// so these are listed even then.
    let databases: () -> [Database]

    let name = "MongoDB"
    let symbol = DatabaseEngine.mongodb.symbol
    let vocabulary = BrowserVocabulary(item: "collection", items: "collections", query: "Query",
                                       queryHint: "Statements such as db.users.find({}), separated by semicolons. Changes can't be undone.")
    var signedInNote: String { "signed in as \(MongoService.adminUser)" }

    func isInstalled(_ setup: SetupStatus) -> Bool { setup.isInstalled(.mongodb) }
    func isRunning(_ state: AppState) -> Bool { state.isRunning(.mongodb) }

    // MARK: Talking to the server

    /// Turns values into the text of a cell, and lists of documents into columns and rows.
    private static let helpers = """
    function __cell(v) {
      if (v === null || v === undefined) return null;
      if (typeof v === 'string') return v;
      if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'bigint') return String(v);
      if (v instanceof Date) return v.toISOString();
      if (v._bsontype === 'ObjectId' || v._bsontype === 'ObjectID') return v.toString();
      try { return EJSON.stringify(v, { relaxed: true }); } catch (e) { return String(v); }
    }
    function __table(docs) {
      const columns = [], seen = {};
      for (const d of docs) for (const k of Object.keys(d)) if (!seen[k]) { seen[k] = true; columns.push(k); }
      return { columns: columns, rows: docs.map(d => columns.map(c => (c in d) ? __cell(d[c]) : null)) };
    }
    function __typeOf(v) {
      if (v === null) return 'null';
      if (Array.isArray(v)) return 'array';
      if (v instanceof Date) return 'date';
      if (v && v._bsontype) return String(v._bsontype).toLowerCase();
      return typeof v;
    }

    """

    /// Runs a script and decodes the JSON it printed last.
    private func run<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let output = try await Mongosh.run(Self.helpers + script)
        guard let line = output.split(whereSeparator: \.isNewline).last,
              let value = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) else {
            throw ShellError("Couldn't read the results from MongoDB.\n\(output)")
        }
        return value
    }

    private func collection(_ item: BrowserItem) -> String {
        "db.getSiblingDB(\(Mongosh.literal(item.database))).getCollection(\(Mongosh.literal(item.name)))"
    }

    // MARK: BrowserEngine

    private struct CatalogReply: Decodable {
        struct Entry: Decodable {
            var name: String
            var view: Bool
            var count: Int?
        }
        var databases: [String]
        var collections: [String: [Entry]]
    }

    func catalog() async throws -> BrowserCatalog {
        let known = databases().map(\.name)
        let reply = try await run("""
        const named = db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name)
          .filter(n => !\(Mongosh.literal(Self.systemDatabases.sorted().joined(separator: ","))).split(',').includes(n));
        const all = Array.from(new Set(named.concat(\(Mongosh.literal(known.joined(separator: "\n"))).split('\\n').filter(n => n)))).sort();
        const collections = {};
        for (const n of all) {
          const d = db.getSiblingDB(n);
          collections[n] = d.getCollectionInfos({}).filter(c => !c.name.startsWith('system.')).map(c => ({
            name: c.name, view: c.type === 'view', count: c.type === 'view' ? null : d.getCollection(c.name).estimatedDocumentCount()
          }));
        }
        print(JSON.stringify({ databases: all, collections: collections }));
        """, as: CatalogReply.self)
        var items: [String: [BrowserItem]] = [:]
        for (database, entries) in reply.collections {
            items[database] = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                var item = BrowserItem(database: database, name: $0.name, isView: $0.view, rows: $0.count)
                item.exact = !$0.view
                return item
            }
        }
        return BrowserCatalog(databases: reply.databases, items: items)
    }

    func exactCounts(for items: [BrowserItem]) async -> [String: Int] { [:] }

    private struct PageReply: Decodable {
        var total: Int
        var columns: [String]
        var rows: [[String?]]
    }

    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage {
        let order = sort.map { "{ [\(Mongosh.literal($0.column))]: \($0.ascending ? 1 : -1) }" } ?? "{}"
        let reply = try await run("""
        const c = \(collection(item));
        const docs = c.find({}).sort(\(order)).skip(\(page * size)).limit(\(size)).toArray();
        const t = __table(docs);
        print(JSON.stringify({ total: c.countDocuments({}), columns: t.columns, rows: t.rows }));
        """, as: PageReply.self)
        return BrowserPage(grid: GridData(columns: reply.columns, rows: reply.rows), total: reply.total)
    }

    private struct StructureReply: Decodable {
        var fields: [[String?]]
        var indexes: [[String?]]
    }

    func structure(of item: BrowserItem) async throws -> [BrowserSection] {
        let reply = try await run("""
        const c = \(collection(item));
        const sample = c.aggregate([{ $sample: { size: 100 } }]).toArray();
        const found = {};
        for (const d of sample) for (const k of Object.keys(d)) {
          found[k] = found[k] || { types: {}, count: 0 };
          found[k].count++;
          found[k].types[__typeOf(d[k])] = true;
        }
        let indexes = [];
        try { indexes = c.getIndexes().map(i => [i.name, Object.keys(i.key).join(', '), i.unique ? 'Yes' : 'No']); } catch (e) {}
        print(JSON.stringify({
          fields: Object.keys(found).map(k => [k, Object.keys(found[k].types).join(', '), found[k].count + ' of ' + sample.length]),
          indexes: indexes
        }));
        """, as: StructureReply.self)
        return [
            BrowserSection(title: "Fields", symbol: "tablecells",
                           grid: GridData(columns: ["Field", "Types", "In a sample"], rows: reply.fields)),
            BrowserSection(title: "Indexes", symbol: "bolt.horizontal",
                           grid: GridData(columns: ["Index", "Fields", "Unique"], rows: reply.indexes)),
        ]
    }

    private struct RunReply: Decodable {
        var results: [QueryResult]
        var error: String?
    }

    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome {
        let statements = Self.statements(in: text).map { statement in
            """
            if (__error === null) {
              try { __results.push(__shape(\(statement))); } catch (e) { __error = String((e && e.message) || e); }
            }
            """
        }.joined(separator: "\n")
        let reply: RunReply
        do { reply = try await runStatements(statements, in: database, limit: limit) } catch {
            // mongosh refuses a script with a syntax error as a whole; its message points into generated code,
            // so only the error line is shown.
            let lines = error.localizedDescription.split(separator: "\n").map(String.init)
            return QueryOutcome(results: [], error: lines.first { $0.contains("Error") } ?? lines.first ?? "The query failed.")
        }
        return QueryOutcome(results: reply.results, error: reply.error)
    }

    private func runStatements(_ statements: String, in database: String, limit: Int) async throws -> RunReply {
        try await run("""
        db = db.getSiblingDB(\(Mongosh.literal(database)));
        const __limit = \(limit);
        const __results = [];
        let __error = null;
        function __shape(r) {
          if (r && typeof r.toArray === 'function') r = r.toArray();
          const plain = x => x !== null && typeof x === 'object' && !x._bsontype && !(x instanceof Date) && !Array.isArray(x);
          if (Array.isArray(r)) {
            if (r.every(plain)) { const t = __table(r.slice(0, __limit)); return { columns: t.columns, rows: t.rows, total: r.length }; }
            return { columns: ['Value'], rows: r.slice(0, __limit).map(x => [__cell(x)]), total: r.length };
          }
          if (plain(r)) { const t = __table([r]); return { columns: t.columns, rows: t.rows, total: 1 }; }
          return { columns: ['Result'], rows: [[__cell(r)]], total: 1 };
        }
        \(statements)
        print(JSON.stringify({ results: __results, error: __error }));
        """, as: RunReply.self)
    }

    /// Splits text at the semicolons that aren't inside brackets, quotes or comments.
    static func statements(in text: String) -> [String] {
        var result: [String] = [], current = ""
        var depth = 0, quote: Character?, escaping = false
        var iterator = text.makeIterator()
        var previous: Character?
        var lineComment = false
        while let character = iterator.next() {
            defer { previous = character }
            if lineComment {
                if character == "\n" { lineComment = false }
                continue
            }
            if let open = quote {
                current.append(character)
                if escaping { escaping = false } else if character == "\\" { escaping = true } else if character == open { quote = nil }
                continue
            }
            if character == "/", previous == "/" {
                lineComment = true
                current.removeLast()
                continue
            }
            switch character {
            case "\"", "'", "`": quote = character; current.append(character)
            case "(", "[", "{": depth += 1; current.append(character)
            case ")", "]", "}": depth -= 1; current.append(character)
            case ";" where depth == 0:
                result.append(current)
                current = ""
            default: current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

}
