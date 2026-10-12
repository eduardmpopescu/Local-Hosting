import Foundation

/// The Browser's view of the private PostgreSQL server. PHP's own `pgsql` extension does the talking: it reports
/// NULLs, binary values and errors precisely, and runs several statements in one go. The credentials and SQL
/// travel over stdin, never on a command line.
@MainActor
struct PostgresEngine: BrowserEngine {
    private static let exactCountLimit = 100_000
    /// PostgreSQL's type numbers for the number types: int8, int2, int4, oid, float4, float8, money and numeric.
    private static let numericTypes: Set<String> = ["20", "21", "23", "26", "700", "701", "790", "1700"]

    let name = "PostgreSQL"
    let symbol = DatabaseEngine.postgresql.symbol
    let vocabulary = BrowserVocabulary()
    var signedInNote: String { "signed in as \(PostgresService.adminUser)" }

    func isInstalled(_ setup: SetupStatus) -> Bool { setup.isInstalled(.postgresql) }
    func isRunning(_ state: AppState) -> Bool { state.isRunning(.postgresql) }

    // MARK: Talking to the server

    struct Job {
        var database: String
        var sql: String
    }

    private struct Response: Decodable {
        var jobs: [QueryResponse]?
        var error: String?
    }

    /// Runs each job on its own connection to its database, and returns what each returned.
    private func run(_ jobs: [Job], limit: Int) async throws -> [QueryResponse] {
        guard let port = PostgresService.port, let password = PostgresService.password else {
            throw ShellError("PostgreSQL isn't running.")
        }
        let payload: [String: Any] = [
            "user": PostgresService.adminUser, "pass": password, "port": port, "limit": limit,
            "jobs": jobs.map { ["db": $0.database, "sql": $0.sql] },
        ]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let result = await Shell.run(Paths.php, ["-d", "display_errors=stderr", "-d", "memory_limit=512M", "-r", Self.script],
                                     input: input)
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) else {
            throw ShellError("Couldn't read the results from PostgreSQL.\n\(result.output)")
        }
        if let message = response.error { throw ShellError(message) }
        return response.jobs ?? []
    }

    private static let script = #"""
    $in = json_decode(stream_get_contents(STDIN), true);
    $q = fn($v) => "'" . addcslashes((string) $v, "'\\") . "'";
    $out = ['jobs' => []];
    foreach ($in['jobs'] as $job) {
        $res = ['results' => []];
        $conn = @pg_connect('host=127.0.0.1 port=' . (int) $in['port'] . ' dbname=' . $q($job['db'])
            . ' user=' . $q($in['user']) . ' password=' . $q($in['pass']) . ' connect_timeout=5');
        if (!$conn) {
            $out['error'] = 'Couldn\'t connect to PostgreSQL.';
            break;
        }
        pg_send_query($conn, $job['sql']);
        while (($r = pg_get_result($conn)) !== false) {
            $status = pg_result_status($r);
            if ($status === PGSQL_TUPLES_OK) {
                $columns = []; $types = [];
                for ($i = 0, $n = pg_num_fields($r); $i < $n; $i++) {
                    $columns[] = pg_field_name($r, $i);
                    // Not pg_field_type(): it asks the server, which would swallow the results still to come.
                    $types[] = (string) pg_field_type_oid($r, $i);
                }
                $rows = [];
                while (count($rows) < $in['limit'] && ($row = pg_fetch_row($r))) {
                    $rows[] = array_map(function ($v) {
                        if ($v === null) return null;
                        if (mb_check_encoding($v, 'UTF-8')) return $v;
                        return '0x' . strtoupper(bin2hex(substr($v, 0, 32))) . (strlen($v) > 32 ? '…' : '');
                    }, $row);
                }
                $res['results'][] = ['columns' => $columns, 'types' => $types, 'rows' => $rows, 'total' => pg_num_rows($r)];
            } elseif ($status === PGSQL_COMMAND_OK) {
                $res['results'][] = ['affected' => max(0, pg_affected_rows($r))];
            } else {
                $res['error'] = pg_result_error($r);
            }
        }
        pg_close($conn);
        $out['jobs'][] = $res;
    }
    echo json_encode($out, JSON_INVALID_UTF8_SUBSTITUTE);
    """#

    private func fail(_ response: QueryResponse) throws {
        if let message = response.error { throw ShellError(message) }
    }

    private func qualified(_ item: BrowserItem) -> String {
        SQLQuote.identifier(item.schema ?? "public") + "." + SQLQuote.identifier(item.name)
    }

    // MARK: BrowserEngine

    func catalog() async throws -> BrowserCatalog {
        let listed = try await run([Job(database: "postgres", sql: """
        SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' ORDER BY datname;
        """)], limit: 10_000)
        try fail(listed[0])
        let databases = (listed[0].results.first?.rows ?? []).compactMap { $0.first ?? nil }

        // A connection sees only its own database, so each one is asked for its tables.
        let tables = try await run(databases.map { Job(database: $0, sql: """
        SELECT n.nspname, c.relname, c.relkind, GREATEST(c.reltuples, 0)::bigint
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname !~ '^pg_toast' ORDER BY 1, 2;
        """) }, limit: 100_000)
        var items: [String: [BrowserItem]] = [:]
        for (database, response) in zip(databases, tables) {
            try fail(response)
            items[database] = (response.results.first?.rows ?? []).compactMap { row in
                guard row.count == 4, let schema = row[0], let name = row[1] else { return nil }
                return BrowserItem(database: database, name: name, schema: schema,
                                   isView: row[2] == "v" || row[2] == "m", rows: row[3].flatMap { Int($0) })
            }
        }
        return BrowserCatalog(databases: databases, items: items)
    }

    /// The catalog's row figures are estimates (and 0 until the table is analyzed), so count the rows of every table that isn't huge.
    func exactCounts(for items: [BrowserItem]) async -> [String: Int] {
        let candidates = items.filter { !$0.isView && ($0.rows ?? 0) < Self.exactCountLimit }
        let byDatabase = Dictionary(grouping: candidates, by: \.database)
        guard !byDatabase.isEmpty else { return [:] }
        let databases = Array(byDatabase.keys)
        let jobs = databases.map { database in
            Job(database: database, sql: byDatabase[database]!.map { item in
                "SELECT \(SQLQuote.literal(item.schema ?? "public")), \(SQLQuote.literal(item.name)), COUNT(*) FROM " + qualified(item)
            }.joined(separator: " UNION ALL ") + ";")
        }
        guard let responses = try? await run(jobs, limit: 1_000) else { return [:] }
        var counts: [String: Int] = [:]
        for (database, response) in zip(databases, responses) where response.error == nil {
            for row in response.results.first?.rows ?? [] where row.count == 3 {
                guard let schema = row[0], let name = row[1], let count = row[2].flatMap({ Int($0) }) else { continue }
                counts[BrowserItem(database: database, name: name, schema: schema, isView: false).id] = count
            }
        }
        return counts
    }

    func page(of item: BrowserItem, sort: BrowserSort?, page: Int, size: Int) async throws -> BrowserPage {
        let from = qualified(item)
        let order = sort.map { " ORDER BY \(SQLQuote.identifier($0.column)) \($0.ascending ? "ASC" : "DESC")" } ?? ""
        let responses = try await run([Job(database: item.database, sql: """
        SELECT COUNT(*) FROM \(from);
        SELECT * FROM \(from)\(order) LIMIT \(size) OFFSET \(page * size);
        """)], limit: 10_000)
        try fail(responses[0])
        let results = responses[0].results
        let total = Int(results.first?.rows?.first?.first.flatMap { $0 } ?? "0") ?? 0
        let rows = results.count > 1 ? results[1] : QueryResult()
        let types = rows.types ?? []
        let grid = GridData(columns: rows.columns ?? [], rows: Array((rows.rows ?? []).prefix(size)),
                            numeric: types.isEmpty ? nil : types.map { Self.numericTypes.contains($0) })
        return BrowserPage(grid: grid, total: total)
    }

    func structure(of item: BrowserItem) async throws -> [BrowserSection] {
        let schema = SQLQuote.literal(item.schema ?? "public"), name = SQLQuote.literal(item.name)
        let responses = try await run([Job(database: item.database, sql: """
        SELECT a.attname, format_type(a.atttypid, a.atttypmod), CASE WHEN a.attnotnull THEN 'No' ELSE 'Yes' END,
               COALESCE(pg_get_expr(d.adbin, d.adrelid), ''),
               CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)) THEN 'PRI' ELSE '' END
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE n.nspname = \(schema) AND c.relname = \(name) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;
        SELECT ic.relname, string_agg(a.attname, ', ' ORDER BY k.ord), CASE WHEN i.indisunique THEN 'Yes' ELSE 'No' END
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE n.nspname = \(schema) AND t.relname = \(name) GROUP BY ic.relname, i.indisunique ORDER BY ic.relname;
        """)], limit: 10_000)
        try fail(responses[0])
        let results = responses[0].results
        return [
            BrowserSection(title: "Columns", symbol: "tablecells",
                           grid: GridData(columns: ["Column", "Type", "Null", "Default", "Key"], rows: results.first?.rows ?? [])),
            BrowserSection(title: "Indexes", symbol: "bolt.horizontal",
                           grid: GridData(columns: ["Index", "Columns", "Unique"], rows: results.count > 1 ? results[1].rows ?? [] : [])),
        ]
    }

    func run(_ text: String, in database: String, limit: Int) async throws -> QueryOutcome {
        let responses = try await run([Job(database: database, sql: text)], limit: limit)
        return QueryOutcome(results: responses[0].results, error: responses[0].error)
    }

}
