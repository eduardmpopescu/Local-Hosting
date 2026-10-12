import Foundation

/// Runs JavaScript in `mongosh`, connected to the private MongoDB server as its admin account.
enum Mongosh {
    /// A JavaScript string literal for any text.
    static func literal(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `script` with `db` connected to the admin database, and returns what it printed. The script
    /// goes in a private temporary file rather than on the command line, because it holds the password.
    @discardableResult
    static func run(_ script: String, what: String = "MongoDB") async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Paths.mongosh) else {
            throw ShellError("mongosh isn't installed yet. Open Settings and install MongoDB.")
        }
        guard let port = MongoService.port, let password = MongoService.password else { throw ShellError("MongoDB isn't running.") }
        return try await run(script, port: port, password: password, what: what)
    }

    @discardableResult
    static func run(_ script: String, port: Int, password: String?, what: String) async throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("localhosting-mongosh-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        var uri = "mongodb://127.0.0.1:\(port)/admin"
        if let password {
            let encoded = password.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? password
            uri = "mongodb://\(MongoService.adminUser):\(encoded)@127.0.0.1:\(port)/admin?authSource=admin"
        }
        let file = dir.appendingPathComponent("script.js")
        try writePrivate("var db = connect(\(literal(uri)));\n" + script, to: file)
        let result = await Shell.run(Paths.mongosh, ["--quiet", "--norc", "--nodb", "--file", file.path])
        guard result.ok else { throw ShellError("\(what) failed.\n\(result.output)") }
        return result.stdout
    }
}

/// A private MongoDB server. It listens on 127.0.0.1 only and needs a login: each database gets a user with
/// access to that database alone.
struct MongoService: DatabaseService {
    static let adminUser = "admin"

    static var password: String? {
        (try? String(contentsOf: Paths.mongoPassword, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var port: Int? {
        (try? String(contentsOf: Paths.mongoPort, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var isRunning: Bool { runningPid(at: Paths.mongoPid) != nil }
    var pid: pid_t? { runningPid(at: Paths.mongoPid) }

    func start(port: Int) async throws {
        guard !isRunning else { return }
        guard DatabaseEngine.mongodb.isInstalled else {
            throw ShellError("MongoDB isn't installed yet. Open Settings and click Install.")
        }
        await stopLeftovers()
        try await Ports.ensureFree(port, for: "MongoDB", hint: "If it's another MongoDB, stop it (for example: brew services stop mongodb-community).")
        try FileManager.default.createDirectory(at: Paths.mongoData, withIntermediateDirectories: true)

        if Self.password == nil {
            // A new data folder accepts the first account without a login. Create the admin account, then restart with logins required.
            try await launch(port: port, requireLogin: false)
            let password = Database.generatePassword(length: 24)
            try await Mongosh.run("""
            db.getSiblingDB("admin").createUser({ user: \(Mongosh.literal(Self.adminUser)), pwd: \(Mongosh.literal(password)), roles: ["root"] });
            """, port: port, password: nil, what: "Creating the MongoDB admin account")
            try writePrivate(password, to: Paths.mongoPassword)
            await stop()
        }
        try await launch(port: port, requireLogin: true)
    }

    /// mongod can't daemonize itself on macOS (`--fork` is refused), so it runs as a child of the app. The app
    /// keeps hold of it so it's reaped when it exits, and stops it when the app quits.
    private static var child: Process?

    private func launch(port: Int, requireLogin: Bool) async throws {
        var arguments = [
            "--dbpath", Paths.mongoData.path, "--bind_ip", "127.0.0.1", "--port", String(port), "--nounixsocket",
            "--logpath", Paths.mongoLog.path, "--logappend", "--pidfilepath", Paths.mongoPid.path,
        ]
        if requireLogin { arguments.append("--auth") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Paths.mongod)
        process.arguments = arguments
        process.environment = Shell.environment
        process.standardInput = FileHandle.nullDevice
        // mongod writes its own log to --logpath.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ShellError("MongoDB did not start: \(error.localizedDescription)")
        }
        Self.child = process
        guard await waitUntilListening(port: port, process: process) else {
            throw ShellError("MongoDB did not start.\n\(Self.tailOfLog())")
        }
        try writePrivate(String(port), to: Paths.mongoPort)
    }

    private func waitUntilListening(port: Int, process: Process) async -> Bool {
        for _ in 0..<80 where process.isRunning {
            if !Ports.isFree(port), isRunning { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// SIGTERM makes MongoDB flush its data and shut down.
    func stop() async {
        guard let pid = runningPid(at: Paths.mongoPid) else { return }
        kill(pid, SIGTERM)
        await waitForExit(of: pid, seconds: 30)
    }

    func stopLeftovers() async { await Leftovers.stop(usingConfig: Paths.mongoData) }

    // MARK: Databases and users

    private static func roles(for databases: [Database]) -> String {
        "[" + databases.map { "{ role: \"readWrite\", db: \(Mongosh.literal($0.name)) }" }.joined(separator: ", ") + "]"
    }

    /// The user lives in the admin database with access to each of their databases, so one user can have several.
    func create(_ db: Database) async throws {
        try await Mongosh.run("""
        const admin = db.getSiblingDB("admin");
        const user = \(Mongosh.literal(db.username));
        const roles = \(Self.roles(for: [db]));
        if (admin.getUser(user)) {
          admin.updateUser(user, { pwd: \(Mongosh.literal(db.password)) });
          admin.grantRolesToUser(user, roles);
        } else {
          admin.createUser({ user: user, pwd: \(Mongosh.literal(db.password)), roles: roles });
        }
        """)
    }

    func drop(_ db: Database, dropUser: Bool) async throws {
        try await Mongosh.run("""
        db.getSiblingDB(\(Mongosh.literal(db.name))).dropDatabase();
        const admin = db.getSiblingDB("admin");
        if (admin.getUser(\(Mongosh.literal(db.username)))) {
          \(dropUser ? "admin.dropUser(\(Mongosh.literal(db.username)));"
                     : "admin.revokeRolesFromUser(\(Mongosh.literal(db.username)), \(Self.roles(for: [db])));")
        }
        """)
    }

    func setPassword(username: String, password: String) async throws {
        try await Mongosh.run("""
        db.getSiblingDB("admin").updateUser(\(Mongosh.literal(username)), { pwd: \(Mongosh.literal(password)) });
        """)
    }

    /// A user without access has no roles; a user with access can read and write every database they own.
    func applyAccess(all: [Database], on: [Database]) async throws {
        let unlocked = Set(on.map(\.username))
        var script = "const admin = db.getSiblingDB(\"admin\");\n"
        for user in Set(all.map(\.username)) {
            let roles = unlocked.contains(user) ? Self.roles(for: all.filter { $0.username == user }) : "[]"
            script += "if (admin.getUser(\(Mongosh.literal(user)))) admin.updateUser(\(Mongosh.literal(user)), { roles: \(roles) });\n"
        }
        try await Mongosh.run(script)
    }

    static func tailOfLog(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: Paths.mongoLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
