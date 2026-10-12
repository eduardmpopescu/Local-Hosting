import Foundation

/// The software that serves a site. Only one of them runs at a time, because both need ports 80 and 443.
enum WebServer: String, Codable, CaseIterable, Identifiable {
    case apache, nginx
    var id: String { rawValue }
    var name: String { self == .apache ? "Apache" : "Nginx" }
    var symbol: String { self == .apache ? "globe" : "network" }

    private static let lastUsedKey = "lastWebServer"

    /// Whichever ran last: new servers start out using it, and the Console shows its log.
    static var lastUsed: WebServer {
        WebServer(rawValue: Paths.preferences.string(forKey: lastUsedKey) ?? "") ?? .apache
    }

    static func remember(_ web: WebServer) { Paths.preferences.set(web.rawValue, forKey: lastUsedKey) }
}

/// What a server serves: PHP files, plain files, or an app that runs its own process.
enum SiteKind: String, Codable, CaseIterable, Identifiable {
    case php, staticSite = "static", node, python, ruby
    var id: String { rawValue }

    var name: String {
        switch self {
        case .php: "PHP"
        case .staticSite: "Static"
        case .node: "Node"
        case .python: "Python"
        case .ruby: "Ruby"
        }
    }

    var symbol: String {
        switch self {
        case .php: "chevron.left.forwardslash.chevron.right"
        case .staticSite: "doc.richtext"
        case .node: "hexagon"
        case .python: "curlybraces"
        case .ruby: "diamond"
        }
    }

    /// Node, Python and Ruby servers run the project's own process behind the web server.
    var isApp: Bool { self == .node || self == .python || self == .ruby }

    var defaultCommand: String {
        switch self {
        case .node: "npm start"
        case .python: "python3 manage.py runserver $PORT"
        case .ruby: "bundle exec rails server -p $PORT"
        default: ""
        }
    }

    var defaultPort: Int {
        switch self {
        case .python: 8000
        default: 3000
        }
    }
}

struct Server: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// The domain this server answers on, e.g. "example.com". If a real website uses it,
    /// that site comes back as soon as the server is switched off.
    var domain: String = ""
    var documentRoot: String
    /// The PHP version that runs this site, e.g. "8.3". Nil means the newest installed.
    var phpVersion: String?

    /// Nil in servers saved before site types existed, which all serve PHP.
    var kind: SiteKind?
    var siteKind: SiteKind { kind ?? .php }
    /// For Node, Python and Ruby servers: what starts the project, and the port it listens on.
    /// The port is also given to the command as $PORT.
    var command: String?
    var port: Int?

    /// Nil in servers saved before Nginx existed, which all use Apache.
    var web: WebServer?
    var webServer: WebServer { web ?? .apache }

    /// URL-safe version of the name, used for `<slug>.test` and file names.
    var slug: String { Server.slug(for: name) }

    /// Only used by servers created before a domain was required.
    var localHostname: String { "\(slug).test" }

    /// Every hostname that points at this server while it's running.
    var hostnames: [String] {
        guard !domain.isEmpty else { return [localHostname] }
        var names = [domain]
        if domain.hasPrefix("www.") {
            names.append(String(domain.dropFirst(4)))
        } else if domain.split(separator: ".").count == 2 {
            names.append("www." + domain)
        }
        return names
    }

    /// The address to open in the browser.
    var primaryHostname: String { domain.isEmpty ? localHostname : domain }

    static func slug(for name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        var slug = ""
        for ch in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                slug.unicodeScalars.append(ch)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "site" : String(slug.prefix(50))
    }

    /// Turns things like "https://www.Example.com/shop" into "www.example.com".
    static func normalizeDomain(_ input: String) -> String {
        var d = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where d.hasPrefix(scheme) {
            d.removeFirst(scheme.count)
        }
        if let cut = d.firstIndex(where: { "/?#:".contains($0) }) {
            d = String(d[..<cut])
        }
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    static func isValidDomain(_ d: String) -> Bool {
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        let pattern = "^\(label)(\\.\(label))+$"
        return d.count <= 253 && d.range(of: pattern, options: .regularExpression) != nil
    }
}

struct Database: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var username: String
    var password: String

    /// Nil in databases saved before other engines existed, which are all MySQL.
    var kind: DatabaseEngine?
    var engine: DatabaseEngine { kind ?? .mysql }
    /// Redis only: the database's number on the server, 0 to 15.
    var index: Int?

    init(name: String, username: String, password: String, kind: DatabaseEngine = .mysql, index: Int? = nil) {
        self.name = name
        self.username = username
        self.password = password
        self.kind = kind == .mysql ? nil : kind
        self.index = index
    }

    /// SQLite only: the file that holds the data.
    var file: URL { Paths.sqliteFile(named: name) }

    static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_]{1,64}$", options: .regularExpression) != nil
    }

    static func isValidUsername(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_]{1,32}$", options: .regularExpression) != nil
    }

    static let reservedNames: Set<String> = ["mysql", "sys", "information_schema", "performance_schema"]
    static let reservedUsers: Set<String> = ["root", "mysql.sys", "mysql.session", "mysql.infoschema"]

    static func generatePassword(length: Int = 16) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

struct AppConfig: Codable {
    var servers: [Server] = []
    var databases: [Database] = []
    var mysqlPort: Int = 3306
    /// The name projects use to reach MySQL. Anything other than localhost or 127.0.0.1
    /// is added to /etc/hosts.
    var mysqlHost: String = "localhost"
    /// Ports changed from the defaults, by engine name. MySQL's is `mysqlPort`.
    var ports: [String: Int] = [:]

    func port(for engine: DatabaseEngine) -> Int {
        engine == .mysql ? mysqlPort : ports[engine.rawValue] ?? engine.defaultPort
    }

    var usesCustomMySQLHost: Bool { !["localhost", "127.0.0.1"].contains(mysqlHost) }

    init() {}

    /// Settings saved by older versions lack newer fields; those get their defaults
    /// instead of making the whole file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        databases = try c.decodeIfPresent([Database].self, forKey: .databases) ?? []
        mysqlPort = try c.decodeIfPresent(Int.self, forKey: .mysqlPort) ?? 3306
        mysqlHost = try c.decodeIfPresent(String.self, forKey: .mysqlHost) ?? "localhost"
        ports = try c.decodeIfPresent([String: Int].self, forKey: .ports) ?? [:]
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return AppConfig() }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) { return config }
        // Keep a copy before the next save replaces it, so servers and passwords can be recovered.
        let backup = Paths.support.appendingPathComponent("config-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: Paths.configFile, to: backup)
        return AppConfig()
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.configFile, options: .atomic)
        // Database passwords live here, so keep the file private.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.configFile.path)
    }
}
