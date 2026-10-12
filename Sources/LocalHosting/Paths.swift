import Foundation

/// Every location Local Hosting reads from or writes to.
enum Paths {
    // MARK: Homebrew binaries

    /// Checked each time, because Homebrew can be installed or removed while the app runs.
    static var brewPrefix: String { FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew" : "/usr/local" }
    static var brew: String { "\(brewPrefix)/bin/brew" }

    static var httpdRoot: String { "\(brewPrefix)/opt/httpd" }
    static var httpd: String { "\(httpdRoot)/bin/httpd" }
    static var httpdModules: String { "\(httpdRoot)/lib/httpd/modules" }
    static var mimeTypes: String { "\(brewPrefix)/etc/httpd/mime.types" }
    /// The command-line PHP the Browser uses to talk to MySQL: the newest installed version.
    static var php: String { PHP.newest()?.cli ?? "\(brewPrefix)/opt/php/bin/php" }

    static var nginx: String { "\(brewPrefix)/opt/nginx/bin/nginx" }
    static var nginxMimeTypes: String { "\(brewPrefix)/etc/nginx/mime.types" }

    static var mysqlBin: String { "\(brewPrefix)/opt/mysql/bin" }
    static var mysqld: String { "\(mysqlBin)/mysqld" }
    static var mysql: String { "\(mysqlBin)/mysql" }
    static var mysqladmin: String { "\(mysqlBin)/mysqladmin" }

    static var redisServer: String { "\(brewPrefix)/opt/redis/bin/redis-server" }
    static var mongod: String { "\(brewPrefix)/opt/mongodb-community/bin/mongod" }
    static var mongosh: String { "\(brewPrefix)/bin/mongosh" }
    /// macOS's own SQLite, which Local Hosting uses for SQLite databases.
    static let sqlite3 = "/usr/bin/sqlite3"

    static var openssl: String {
        let brewed = "\(brewPrefix)/opt/openssl@3/bin/openssl"
        return FileManager.default.fileExists(atPath: brewed) ? brewed : "/usr/bin/openssl"
    }

    // MARK: App data (~/Library/Application Support/Local Hosting)

    /// True when running against a separate data folder (LOCAL_HOSTING_DATA_DIR) for testing.
    static let isTestRun = !(ProcessInfo.processInfo.environment["LOCAL_HOSTING_DATA_DIR"] ?? "").isEmpty

    /// Where remembered choices (open page, console tab) are kept. Test runs use their own store,
    /// so they never change what the real app shows, and the real app never changes them.
    static let preferences: UserDefaults = isTestRun
        ? UserDefaults(suiteName: "com.eduardmpopescu.localhosting.tests") ?? .standard
        : .standard

    /// In test runs, LOCAL_HOSTING_OPEN_SHEET=server|database opens that sheet on launch for screenshots.
    static var testSheet: String? {
        isTestRun ? ProcessInfo.processInfo.environment["LOCAL_HOSTING_OPEN_SHEET"] : nil
    }

    /// In test runs, LOCAL_HOSTING_OPEN_TABLE=database.table[:mode] opens that table in the Browser.
    static var testTable: String? {
        isTestRun ? ProcessInfo.processInfo.environment["LOCAL_HOSTING_OPEN_TABLE"] : nil
    }

    /// In test runs, LOCAL_HOSTING_OPEN_MENU=server opens the first server's right-click menu.
    static var testMenu: String? {
        isTestRun ? ProcessInfo.processInfo.environment["LOCAL_HOSTING_OPEN_MENU"] : nil
    }

    /// Set LOCAL_HOSTING_DATA_DIR to run against a separate folder (used for testing).
    static let support: URL = {
        if let custom = ProcessInfo.processInfo.environment["LOCAL_HOSTING_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Local Hosting", isDirectory: true)
    }()

    static var configFile: URL { support.appendingPathComponent("config.json") }

    static var apacheDir: URL { support.appendingPathComponent("apache", isDirectory: true) }
    static var httpdConf: URL { apacheDir.appendingPathComponent("httpd.conf") }
    static var apacheRun: URL { apacheDir.appendingPathComponent("run", isDirectory: true) }
    static var apachePid: URL { apacheRun.appendingPathComponent("httpd.pid") }
    static var apacheLogs: URL { apacheDir.appendingPathComponent("logs", isDirectory: true) }
    static var apacheErrorLog: URL { apacheLogs.appendingPathComponent("error.log") }
    static var fallbackSite: URL { apacheDir.appendingPathComponent("default", isDirectory: true) }

    static var appsDir: URL { support.appendingPathComponent("apps", isDirectory: true) }
    /// Output of every Node, Python and Ruby server, each line starting with the server's name.
    static var appsLog: URL { appsDir.appendingPathComponent("apps.log") }

    static var nginxDir: URL { support.appendingPathComponent("nginx", isDirectory: true) }
    static var nginxConf: URL { nginxDir.appendingPathComponent("nginx.conf") }
    static var nginxFastCGI: URL { nginxDir.appendingPathComponent("fastcgi_params") }
    static var nginxRun: URL { nginxDir.appendingPathComponent("run", isDirectory: true) }
    static var nginxPid: URL { nginxRun.appendingPathComponent("nginx.pid") }
    static var nginxTmp: URL { nginxDir.appendingPathComponent("tmp", isDirectory: true) }
    static var nginxLogs: URL { nginxDir.appendingPathComponent("logs", isDirectory: true) }
    static var nginxErrorLog: URL { nginxLogs.appendingPathComponent("error.log") }

    static var phpDir: URL { support.appendingPathComponent("php", isDirectory: true) }
    static var phpRun: URL { phpDir.appendingPathComponent("run", isDirectory: true) }
    /// PHP errors from every version, and PHP-FPM's own messages.
    static var phpLog: URL { phpDir.appendingPathComponent("error.log") }

    static var mysqlDir: URL { support.appendingPathComponent("mysql", isDirectory: true) }
    static var mysqlData: URL { mysqlDir.appendingPathComponent("data", isDirectory: true) }
    static var mysqlRun: URL { mysqlDir.appendingPathComponent("run", isDirectory: true) }
    static var mysqlSocket: URL { mysqlRun.appendingPathComponent("mysql.sock") }
    static var mysqlPid: URL { mysqlRun.appendingPathComponent("mysqld.pid") }
    static var mysqlErrorLog: URL { mysqlDir.appendingPathComponent("error.log") }
    static var myCnf: URL { mysqlDir.appendingPathComponent("my.cnf") }
    static var clientCnf: URL { mysqlDir.appendingPathComponent("client.cnf") }
    static var mysqlRootPassword: URL { mysqlDir.appendingPathComponent("root-password") }

    static var postgresDir: URL { support.appendingPathComponent("postgres", isDirectory: true) }
    static var postgresData: URL { postgresDir.appendingPathComponent("data", isDirectory: true) }
    static var postgresLog: URL { postgresDir.appendingPathComponent("postgres.log") }
    static var postgresPassword: URL { postgresDir.appendingPathComponent("admin-password") }

    static var redisDir: URL { support.appendingPathComponent("redis", isDirectory: true) }
    static var redisData: URL { redisDir.appendingPathComponent("data", isDirectory: true) }
    static var redisConf: URL { redisDir.appendingPathComponent("redis.conf") }
    static var redisPid: URL { redisDir.appendingPathComponent("redis.pid") }
    static var redisLog: URL { redisDir.appendingPathComponent("redis.log") }
    /// One password for the whole Redis server: its databases are numbered, not separate accounts.
    static var redisPassword: URL { redisDir.appendingPathComponent("password") }

    static var mongoDir: URL { support.appendingPathComponent("mongodb", isDirectory: true) }
    static var mongoData: URL { mongoDir.appendingPathComponent("data", isDirectory: true) }
    static var mongoPid: URL { mongoDir.appendingPathComponent("mongod.pid") }
    static var mongoLog: URL { mongoDir.appendingPathComponent("mongod.log") }
    static var mongoPassword: URL { mongoDir.appendingPathComponent("admin-password") }
    static var mongoPort: URL { mongoDir.appendingPathComponent("port") }

    /// Where SQLite databases are kept: one file each.
    static var sqliteDir: URL { support.appendingPathComponent("sqlite", isDirectory: true) }
    static func sqliteFile(named name: String) -> URL { sqliteDir.appendingPathComponent(name + ".sqlite") }

    static var sslDir: URL { support.appendingPathComponent("ssl", isDirectory: true) }
    static var caKey: URL { sslDir.appendingPathComponent("ca.key") }
    static var caCert: URL { sslDir.appendingPathComponent("ca.pem") }
    static var serverCerts: URL { sslDir.appendingPathComponent("servers", isDirectory: true) }

    /// Default parent folder for new sites.
    static var sites: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites", isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [support, apacheRun, apacheLogs, fallbackSite, appsDir, nginxRun, nginxLogs, nginxTmp, phpRun, mysqlRun, sslDir, serverCerts] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Reads a pid file and checks that the process is still alive.
func runningPid(at url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0, kill(pid, 0) == 0 || errno == EPERM
    else { return nil }
    return pid
}

/// Quotes a string for /bin/sh.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
