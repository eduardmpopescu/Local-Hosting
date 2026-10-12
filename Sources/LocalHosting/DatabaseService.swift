import Foundation

/// A database server Local Hosting runs privately, with its own data folder, separate from any Homebrew service.
/// It runs while at least one of its databases is switched on.
protocol DatabaseService {
    var isRunning: Bool { get }
    /// The server's main process, while it runs.
    var pid: pid_t? { get }
    func start(port: Int) async throws
    func stop() async
    /// Stops processes of this server that Local Hosting lost track of, e.g. after a crash.
    func stopLeftovers() async
    func create(_ db: Database) async throws
    func drop(_ db: Database, dropUser: Bool) async throws
    func setPassword(username: String, password: String) async throws
    /// Lets the users of the databases in `on` connect and keeps every other user of `all` out. A locked
    /// user's data is untouched: this is how one database is switched off while the server keeps serving the others.
    func applyAccess(all: [Database], on: [Database]) async throws
}

enum Services {
    /// The server behind an engine, or nil for SQLite, which has none.
    static func of(_ engine: DatabaseEngine) -> (any DatabaseService)? {
        switch engine {
        case .mysql: MySQLService()
        case .postgresql: PostgresService()
        case .mongodb: MongoService()
        case .redis: RedisService()
        case .sqlite: nil
        }
    }
}

struct MySQLService: DatabaseService {
    var isRunning: Bool { MySQL.isRunning }
    var pid: pid_t? { runningPid(at: Paths.mysqlPid) }
    func start(port: Int) async throws { try await MySQL.start(port: port) }
    func stop() async { await MySQL.stop() }
    func stopLeftovers() async { await Leftovers.stop(usingConfig: Paths.myCnf) }
    func create(_ db: Database) async throws { try await MySQL.createDatabase(db) }
    func drop(_ db: Database, dropUser: Bool) async throws { try await MySQL.dropDatabase(db, dropUser: dropUser) }
    func setPassword(username: String, password: String) async throws {
        try await MySQL.setPassword(username: username, password: password)
    }

    func applyAccess(all: [Database], on: [Database]) async throws {
        let unlocked = Set(on.map(\.username))
        try await MySQL.setAccess(unlocked: unlocked, locked: Set(all.map(\.username)).subtracting(unlocked))
    }
}

/// Quoting for SQL text, shared by the engines that take SQL.
enum SQLQuote {
    static func literal(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    static func identifier(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// Reads the first lines of a small text file, e.g. a pid file.
func fileLines(at url: URL) -> [String]? {
    (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// Writes a file only its owner can read.
func writePrivate(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// Whether a process is alive.
func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Waits for a process to end after it was asked to, forcing it only if it doesn't.
func waitForExit(of pid: pid_t, seconds: Int = 15) async {
    for _ in 0..<(seconds * 10) where isAlive(pid) {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if isAlive(pid) {
        kill(pid, SIGKILL)
        for _ in 0..<20 where isAlive(pid) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
}
