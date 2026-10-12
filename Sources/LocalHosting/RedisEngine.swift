import Foundation

/// The Browser's view of the private Redis server. A database is one of Redis's numbered databases; its items are
/// its keys, tagged with their type. Rows shows a key's value, Structure its type, expiry and size, and the query
/// tab takes Redis commands, one per line.
@MainActor
struct RedisEngine: BrowserEngine {
    /// Keys listed per database. A database with more shows the first of them.
    private static let keyLimit = 1_000

    /// The Redis databases that exist.
    let databases: () -> [Database]

    let name = "Redis"
    let symbol = DatabaseEngine.redis.symbol
    let vocabulary = BrowserVocabulary(item: "key", items: "keys", query: "Commands",
                                       queryHint: "One command per line, for example GET name. Changes can't be undone.",
                                       sortable: false)
    var signedInNote: String { "connected with the server's password" }

    func isInstalled(_ setup: SetupStatus) -> Bool { setup.isInstalled(.redis) }
    func isRunning(_ state: AppState) -> Bool { state.isRunning(.redis) }

    private func number(of database: String) throws -> Int {
        guard let index = databases().first(where: { $0.name == database })?.index else {
            throw ShellError("“\(database)” isn't a Redis database.")
        }
        return index
    }

    // MARK: Catalog

    func catalog() async throws -> BrowserCatalog {
        let known = databases().compactMap { db in db.index.map { (name: db.name, index: $0) } }
        var items: [String: [BrowserItem]] = [:]
        for (name, index) in known {
            items[name] = try await RedisService.connect(database: index) { connection in
                var keys: [String] = []
                var cursor = "0"
                repeat {
                    guard case .array(let parts?) = try connection.command(["SCAN", cursor, "COUNT", "500"]), parts.count == 2,
                          case .bulk(let next?) = parts[0], case .array(let found?) = parts[1] else { break }
                    cursor = next
                    keys += found.compactMap { reply -> String? in if case .bulk(let key?) = reply { key } else { nil } }
                } while cursor != "0" && keys.count < Self.keyLimit
                keys = Array(keys.sorted().prefix(Self.keyLimit))

                let types = try connection.pipeline(keys.map { ["TYPE", $0] }).map { $0.text ?? "none" }
                let sizeCommands = zip(keys, types).map { key, type -> [String] in
                    switch type {
                    case "list": ["LLEN", key]
                    case "hash": ["HLEN", key]
                    case "set": ["SCARD", key]
                    case "zset": ["ZCARD", key]
                    case "stream": ["XLEN", key]
                    default: ["STRLEN", key]
                    }
                }
                let sizes = try connection.pipeline(sizeCommands)
                return keys.indices.map { i in
                    var item = BrowserItem(database: name, name: keys[i], isView: false, badge: types[i])
                    // A string's size is its length in bytes, not a count of rows.
                    if types[i] != "string", case .integer(let n) = sizes[i] { item.rows = n }
                    item.exact = true
                    return item
                }
            }
        }
        return BrowserCatalog(databases: known.map(\.name), items: items)
    }

    func exactCounts(for items: [BrowserItem]) async -> [String: Int] { [:] }

    // MARK: Rows and structure

    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage {
        let index = try number(of: item.database)
        let start = page * size, end = start + size - 1
        let type = item.badge ?? "string"
        return try await RedisService.connect(database: index) { connection in
            func pairs(_ reply: RedisReply) -> [(String, String)] {
                guard case .array(let flat?) = reply else { return [] }
                return stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0].text ?? "", flat[$0 + 1].text ?? "") }
            }
            func column(_ reply: RedisReply) -> [String] {
                guard case .array(let all?) = reply else { return [] }
                return all.map { $0.text ?? "" }
            }
            switch type {
            case "hash":
                let all = pairs(try connection.command(["HGETALL", item.name])).sorted { $0.0 < $1.0 }
                return BrowserPage(grid: GridData(columns: ["Field", "Value"], rows: all.dropFirst(start).prefix(size).map { [$0.0, $0.1] }),
                                   total: all.count)
            case "list":
                let total = Int(try connection.command(["LLEN", item.name]).text ?? "0") ?? 0
                let values = column(try connection.command(["LRANGE", item.name, String(start), String(end)]))
                return BrowserPage(grid: GridData(columns: ["Index", "Value"], rows: values.enumerated().map { [String(start + $0.offset), $0.element] },
                                                  numeric: [true, false]), total: total)
            case "set":
                let all = column(try connection.command(["SMEMBERS", item.name])).sorted()
                return BrowserPage(grid: GridData(columns: ["Member"], rows: all.dropFirst(start).prefix(size).map { [$0] }), total: all.count)
            case "zset":
                let total = Int(try connection.command(["ZCARD", item.name]).text ?? "0") ?? 0
                let members = pairs(try connection.command(["ZRANGE", item.name, String(start), String(end), "WITHSCORES"]))
                return BrowserPage(grid: GridData(columns: ["Member", "Score"], rows: members.map { [$0.0, $0.1] }, numeric: [false, true]), total: total)
            case "stream":
                let total = Int(try connection.command(["XLEN", item.name]).text ?? "0") ?? 0
                guard case .array(let entries?) = try connection.command(["XRANGE", item.name, "-", "+", "COUNT", String(size)]) else {
                    return BrowserPage(grid: GridData(columns: ["ID", "Fields"], rows: []), total: total)
                }
                let rows: [[String?]] = entries.map { entry in
                    guard case .array(let parts?) = entry, parts.count == 2, case .array(let fields?) = parts[1] else { return [entry.text, nil] }
                    let named = stride(from: 0, to: fields.count - 1, by: 2).map { "\(fields[$0].text ?? "")=\(fields[$0 + 1].text ?? "")" }
                    return [parts[0].text, named.joined(separator: " ")]
                }
                return BrowserPage(grid: GridData(columns: ["ID", "Fields"], rows: rows), total: total)
            default:
                let value = try connection.command(["GET", item.name])
                if case .bulk(nil) = value { return BrowserPage(grid: GridData(columns: ["Value"], rows: []), total: 0) }
                return BrowserPage(grid: GridData(columns: ["Value"], rows: [[value.text]]), total: 1)
            }
        }
    }

    func structure(of item: BrowserItem) async throws -> [BrowserSection] {
        let index = try number(of: item.database)
        let replies = try await RedisService.connect(database: index) { connection in
            try connection.pipeline([["TYPE", item.name], ["TTL", item.name], ["OBJECT", "ENCODING", item.name], ["MEMORY", "USAGE", item.name]])
        }
        let ttl = Int(replies[1].text ?? "") ?? -1
        let memory = Int(replies[3].text ?? "")
        var rows: [[String?]] = [
            ["Type", replies[0].text],
            ["Expires", ttl >= 0 ? "in \(ttl) seconds" : (ttl == -2 ? "Key is gone" : "Never")],
            ["Encoding", replies[2].errorMessage == nil ? replies[2].text : nil],
        ]
        if let count = item.rows { rows.append(["Length", count.formatted()]) }
        if let memory { rows.append(["Memory", ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)]) }
        return [BrowserSection(title: "Key", symbol: "key", grid: GridData(columns: ["Property", "Value"], rows: rows))]
    }

    // MARK: Commands

    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome {
        let index = try number(of: database)
        let commands = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map(Self.words)
        return try await RedisService.connect(database: index) { connection in
            var results: [QueryResult] = []
            for command in commands {
                let reply = try connection.command(command)
                if let message = reply.errorMessage { return QueryOutcome(results: results, error: message) }
                switch reply {
                case .array(let items?):
                    results.append(QueryResult(columns: ["Value"], rows: items.prefix(limit).map { [$0.text] }, total: items.count))
                default:
                    results.append(QueryResult(columns: ["Result"], rows: [[reply.text ?? "(nil)"]], total: 1))
                }
            }
            return QueryOutcome(results: results, error: nil)
        }
    }

    /// Splits a command line into words, keeping "quoted text" and 'quoted text' together.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, started = false
        var escaping = false
        for character in line {
            if escaping {
                current.append(["n": "\n", "t": "\t", "r": "\r"][character] ?? character)
                escaping = false
            } else if character == "\\", quote == "\"" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

}
