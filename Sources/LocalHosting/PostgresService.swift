import Foundation

/// A private PostgreSQL server with its own data folder. It listens on 127.0.0.1 only, has no Unix socket,
/// and every account needs a password.
struct PostgresService: DatabaseService {
    static let adminUser = "postgres"

    // MARK: The installed software

    /// Homebrew formulae of the PostgreSQL versions installed, newest first.
    static func installedFormulae() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: "\(Paths.brewPrefix)/opt")) ?? []
        return names
            .filter { $0.hasPrefix("postgresql@") && fm.isExecutableFile(atPath: "\(Paths.brewPrefix)/opt/\($0)/bin/postgres") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// The version that runs: the one that made the data folder (a data folder only works with its own major
    /// version), otherwise the newest.
    static var formula: String? {
        let installed = installedFormulae()
        if let text = try? String(contentsOf: Paths.postgresData.appendingPathComponent("PG_VERSION"), encoding: .utf8),
           let major = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), installed.contains("postgresql@\(major)") {
            return "postgresql@\(major)"
        }
        return installed.first
    }

    static var binDir: String? { formula.map { "\(Paths.brewPrefix)/opt/\($0)/bin" } }

    // MARK: State

    static var isInitialized: Bool {
        FileManager.default.fileExists(atPath: Paths.postgresData.appendingPathComponent("PG_VERSION").path)
    }

    static var password: String? {
        (try? String(contentsOf: Paths.postgresPassword, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// postmaster.pid: the process id, the data folder, when it started, then the port.
    private static var pidFile: [String]? { fileLines(at: Paths.postgresData.appendingPathComponent("postmaster.pid")) }

    static var pid: pid_t? {
        guard let lines = pidFile, let first = lines.first, let pid = pid_t(first), pid > 0, isAlive(pid) else { return nil }
        return pid
    }

    /// The port the running server listens on.
    static var port: Int? {
        guard let lines = pidFile, lines.count > 3 else { return nil }
        return Int(lines[3])
    }

    var isRunning: Bool { Self.pid != nil }
    var pid: pid_t? { Self.pid }

    // MARK: Lifecycle

    func start(port: Int) async throws {
        guard !isRunning else { return }
        guard let bin = Self.binDir else { throw ShellError("PostgreSQL isn't installed yet. Open Settings and click Install.") }
        await stopLeftovers()
        try await Ports.ensureFree(port, for: "PostgreSQL", hint: "If it's another PostgreSQL, stop it (for example: brew services stop postgresql@18).")
        try FileManager.default.createDirectory(at: Paths.postgresDir, withIntermediateDirectories: true)
        if !Self.isInitialized { try await Self.initialize(bin: bin) }

        let result = await Shell.run("\(bin)/pg_ctl", [
            "start", "-D", Paths.postgresData.path, "-l", Paths.postgresLog.path, "-w", "-t", "60",
            "-o", "-p \(port) -c listen_addresses=127.0.0.1 -c unix_socket_directories=",
        ])
        guard result.ok, isRunning else {
            throw ShellError("PostgreSQL did not start.\n\(result.output)\n\(Self.tailOfLog())")
        }
    }

    /// Creates the data folder, with a generated password for the admin account.
    private static func initialize(bin: String) async throws {
        let fm = FileManager.default
        // initdb refuses a data folder that isn't empty; clear any half-finished attempt.
        try? fm.removeItem(at: Paths.postgresData)
        let password = Database.generatePassword(length: 24)
        let file = Paths.postgresDir.appendingPathComponent("initial-password")
        try writePrivate(password, to: file)
        defer { try? fm.removeItem(at: file) }
        try await Shell.check("\(bin)/initdb", [
            "-D", Paths.postgresData.path, "-U", adminUser, "--auth=scram-sha-256", "--pwfile=\(file.path)",
            "-E", "UTF8", "--locale=en_US.UTF-8",
        ], what: "Initializing PostgreSQL")
        try writePrivate(password, to: Paths.postgresPassword)
    }

    func stop() async {
        guard let pid = Self.pid else { return }
        if let bin = Self.binDir {
            _ = await Shell.run("\(bin)/pg_ctl", ["stop", "-D", Paths.postgresData.path, "-m", "fast", "-w", "-t", "30"])
        }
        if isAlive(pid) {
            kill(pid, SIGINT)
            await waitForExit(of: pid)
        }
    }

    func stopLeftovers() async { await Leftovers.stop(usingConfig: Paths.postgresData) }

    // MARK: Databases and users

    /// Runs SQL as the admin account, fed through stdin so no secrets show up in the process list.
    @discardableResult
    static func execute(_ sql: String) async throws -> String {
        guard let bin = binDir, let port, let password else { throw ShellError("PostgreSQL isn't running.") }
        return try await Shell.check("\(bin)/psql", [
            "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
            "-h", "127.0.0.1", "-p", String(port), "-U", adminUser, "-d", "postgres",
        ], input: sql, environment: ["PGPASSWORD": password], what: "PostgreSQL").stdout
    }

    func create(_ db: Database) async throws {
        let user = SQLQuote.identifier(db.username), pass = SQLQuote.literal(db.password)
        try await Self.execute("""
        DO $localhosting$ BEGIN
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = \(SQLQuote.literal(db.username))) THEN
            ALTER ROLE \(user) WITH LOGIN PASSWORD \(pass);
          ELSE
            CREATE ROLE \(user) WITH LOGIN PASSWORD \(pass);
          END IF;
        END $localhosting$;
        CREATE DATABASE \(SQLQuote.identifier(db.name)) OWNER \(user);
        """)
    }

    func drop(_ db: Database, dropUser: Bool) async throws {
        var sql = "DROP DATABASE IF EXISTS \(SQLQuote.identifier(db.name)) WITH (FORCE);\n"
        if dropUser { sql += "DROP ROLE IF EXISTS \(SQLQuote.identifier(db.username));\n" }
        try await Self.execute(sql)
    }

    func setPassword(username: String, password: String) async throws {
        try await Self.execute("ALTER ROLE \(SQLQuote.identifier(username)) WITH PASSWORD \(SQLQuote.literal(password));")
    }

    func applyAccess(all: [Database], on: [Database]) async throws {
        let unlocked = Set(on.map(\.username))
        var sql = ""
        for user in Set(all.map(\.username)) {
            // There's no ALTER ROLE IF EXISTS, so the role is looked up first.
            sql += """
            DO $localhosting$ BEGIN
              IF EXISTS (SELECT FROM pg_roles WHERE rolname = \(SQLQuote.literal(user))) THEN
                ALTER ROLE \(SQLQuote.identifier(user)) WITH \(unlocked.contains(user) ? "LOGIN" : "NOLOGIN");
              END IF;
            END $localhosting$;

            """
        }
        if !sql.isEmpty { try await Self.execute(sql) }
    }

    static func tailOfLog(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: Paths.postgresLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
