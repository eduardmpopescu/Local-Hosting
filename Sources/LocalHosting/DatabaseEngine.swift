import Foundation

/// The software behind a database. MySQL, PostgreSQL, MongoDB and Redis each run as their own private
/// server; SQLite is only a file.
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
    case mysql, postgresql, mongodb, redis, sqlite
    var id: String { rawValue }

    var name: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .sqlite: "SQLite"
        }
    }

    var symbol: String {
        switch self {
        case .mysql: "cylinder.split.1x2"
        case .postgresql: "cylinder"
        case .mongodb: "leaf"
        case .redis: "memorychip"
        case .sqlite: "externaldrive"
        }
    }

    /// Runs as a server process with its own data folder. SQLite has none.
    var hasServer: Bool { self != .sqlite }

    /// Each database has its own user and password.
    var hasAccounts: Bool { self == .mysql || self == .postgresql || self == .mongodb }

    var defaultPort: Int {
        switch self {
        case .mysql: 3306
        case .postgresql: 5432
        case .mongodb: 27017
        case .redis: 6379
        case .sqlite: 0
        }
    }

    var browseTitle: String { "Browse" }

    /// What the Settings row says the software is for.
    var detail: String {
        switch self {
        case .mysql: "Holds your databases"
        case .postgresql: "Holds your PostgreSQL databases"
        case .mongodb: "Holds your MongoDB databases. Comes from MongoDB's own Homebrew tap"
        case .redis: "Keeps your Redis data, for caches, sessions and queues"
        case .sqlite: "Needs nothing installed"
        }
    }

    /// The Homebrew commands that install it, run one after the other. MongoDB's server isn't in Homebrew's own
    /// list, so it comes from MongoDB's tap, and Homebrew only loads formulae from a tap once they're trusted:
    /// the three the install loads (the server, its database tools, and `mongodb-enterprise`, which the server
    /// says it conflicts with) are trusted by name, not the whole tap.
    var installCommands: [[String]] {
        switch self {
        case .mysql: [["install", "mysql"]]
        case .postgresql: [["install", "postgresql"]]
        case .mongodb: [
            ["tap", "mongodb/brew"],
            ["trust", "--formula", "mongodb/brew/mongodb-community", "mongodb/brew/mongodb-database-tools",
             "mongodb/brew/mongodb-enterprise"],
            ["install", "mongodb/brew/mongodb-community", "mongosh"],
        ]
        case .redis: [["install", "redis"]]
        case .sqlite: []
        }
    }

    /// Names that are the engine's own and can't be given to a database.
    var reservedNames: Set<String> {
        switch self {
        case .mysql: Database.reservedNames
        case .postgresql: ["postgres", "template0", "template1"]
        case .mongodb: ["admin", "config", "local"]
        case .redis, .sqlite: []
        }
    }

    /// Accounts that are the engine's own and can't be given to a database.
    var reservedUsers: Set<String> {
        switch self {
        case .mysql: Database.reservedUsers
        case .postgresql: ["postgres"]
        case .mongodb: ["admin"]
        case .redis, .sqlite: []
        }
    }

    // MARK: Installed software

    /// The program whose presence means the engine is installed.
    var executable: String? {
        switch self {
        case .mysql: Paths.mysqld
        case .postgresql: PostgresService.binDir.map { "\($0)/postgres" }
        case .mongodb: FileManager.default.isExecutableFile(atPath: Paths.mongosh) ? Paths.mongod : nil
        case .redis: Paths.redisServer
        case .sqlite: nil
        }
    }

    var isInstalled: Bool {
        self == .sqlite || executable.map { FileManager.default.isExecutableFile(atPath: $0) } == true
    }

    /// The folder under Homebrew's `opt` that leads to the installed version.
    private var optName: String? {
        switch self {
        case .mysql: "mysql"
        case .postgresql: PostgresService.formula
        case .mongodb: "mongodb-community"
        case .redis: "redis"
        case .sqlite: nil
        }
    }

    /// The Homebrew formula behind the installed software, e.g. "postgresql@18". Updates are looked up by it.
    /// Read from where `opt/<name>` leads: `…/Cellar/postgresql@18/18.6`.
    var installedFormula: String? {
        guard let optName,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(Paths.brewPrefix)/opt/\(optName)")
        else { return nil }
        let parts = target.split(separator: "/")
        guard let cellar = parts.firstIndex(of: "Cellar"), parts.indices.contains(cellar + 1) else { return nil }
        return String(parts[cellar + 1])
    }

    /// Part of the setup fingerprint: changes when the software is installed, removed or upgraded.
    var fingerprint: String {
        guard isInstalled, hasServer else { return "0" }
        let target = optName.flatMap { try? FileManager.default.destinationOfSymbolicLink(atPath: "\(Paths.brewPrefix)/opt/\($0)") }
        return target ?? "1"
    }

    /// Asks the program for its version.
    func version() async -> String? {
        switch self {
        case .mysql:
            return Self.version(in: await Shell.run(Paths.mysqld, ["--version"]).stdout, after: "Ver ")
        case .postgresql:
            guard let bin = PostgresService.binDir else { return nil }
            return Self.version(in: await Shell.run("\(bin)/postgres", ["--version"]).stdout, after: "(PostgreSQL) ")
        case .mongodb:
            return Self.version(in: await Shell.run(Paths.mongod, ["--version"]).stdout, after: "db version v")
        case .redis:
            return Self.version(in: await Shell.run(Paths.redisServer, ["--version"]).stdout, after: "v=")
        case .sqlite:
            return nil
        }
    }

    /// Pulls "8.0.45" out of output like "mysqld  Ver 8.0.45 for macos on arm64".
    static func version(in output: String, after marker: String) -> String? {
        guard let range = output.range(of: marker) else { return nil }
        return output[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
    }
}
