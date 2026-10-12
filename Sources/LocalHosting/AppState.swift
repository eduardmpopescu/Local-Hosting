import AppKit
import Foundation

struct SetupStatus {
    var brew = false
    var httpd = false
    var nginx = false
    var caTrusted = false
    var helperInstalled = false
    var checked = false
    var httpdVersion: String?
    var brewVersion: String?
    var nginxVersion: String?
    /// Installed PHP versions, newest first, with their full numbers.
    var phpVersions: [PHP.Version] = []
    var phpFullVersions: [String: String] = [:]
    /// Node, Python and Ruby from Homebrew, with their versions. Optional: servers of those kinds need them.
    var runtimes: Set<Runtime> = []
    var runtimeVersions: [Runtime: String] = [:]
    var runtimeFormulae: [Runtime: String] = [:]

    /// Database servers installed, with their versions and the Homebrew formulae behind them.
    var engines: Set<DatabaseEngine> = []
    var engineVersions: [DatabaseEngine: String] = [:]
    var engineFormulae: [DatabaseEngine: String] = [:]

    var mysql: Bool { engines.contains(.mysql) }

    /// SQLite needs nothing installed.
    func isInstalled(_ engine: DatabaseEngine) -> Bool { engine == .sqlite || engines.contains(engine) }

    var readyCount: Int { [packagesInstalled, caTrusted, helperInstalled].filter { $0 }.count }

    var php: Bool { !phpVersions.isEmpty }
    var packagesInstalled: Bool { httpd && php && mysql }
    var complete: Bool { packagesInstalled && caTrusted && helperInstalled }
}

@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig
    /// Memory and disk use of the servers and databases, for the pages that show them.
    let resources = ResourceMonitor()
    @Published private(set) var runningServers: Set<UUID> = []
    /// Databases switched on. MySQL runs while at least one is on; the others' users are locked.
    @Published private(set) var runningDatabases: Set<UUID> = []
    /// A page another page asks to show, e.g. "Browse" opens the Browser.
    @Published var navigationRequest: SidebarItem?
    /// PHP versions that still get fixes, from php.net. Others are no longer offered for install.
    @Published private(set) var supportedPHP = Paths.preferences.stringArray(forKey: "supportedPHP") ?? PHP.fallbackSupported
    /// Installed Homebrew software with a newer version available: formula name to the new version.
    @Published private(set) var updates: [String: String] = [:]
    private var lastUpdateCheck: Date?
    @Published private(set) var webServerRunning = false
    /// The web server that last ran; the Console shows its log.
    @Published private(set) var lastWebServer = WebServer.lastUsed
    /// Database servers that are running: each runs while at least one of its databases is on.
    @Published private(set) var runningEngines: Set<DatabaseEngine> = []
    /// How many queued or running operations each key (a server id, "mysql", …) has.
    @Published private(set) var busy: [String: Int] = [:]
    @Published var setup = SetupStatus()
    @Published var error: String?
    /// A database the Browser should open, e.g. after "Browse" on a database card.
    @Published var browseRequest: String?

    /// Operations run one at a time so Apache and /etc/hosts never see interleaved changes.
    private var queue: Task<Void, Never>?

    init() {
        Paths.ensureDirectories()
        config = AppConfig.load()
        // Coming back to the app after changes made elsewhere (System Settings, Keychain Access, Terminal).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshSetup() }
        }
        enqueue("startup") { [weak self] in
            guard let self else { return }
            await self.cleanUpLeftovers()
            await self.refreshSetup()
            self.removeOldWebDashboard()
            // Restores a custom MySQL host name in /etc/hosts.
            if self.setup.packagesInstalled { try await self.applyServers() }
            // Screenshot runs only: switch on the database whose table should open.
            if let spec = Paths.testTable, let name = spec.split(separator: ".").first.map(String.init) {
                self.browse(name)
            }
        }
    }

    /// Every row in Settings is installed: all of Software (every PHP version still supported included)
    /// and Security. More than `setup.complete`, which only covers what servers need to start.
    var everythingInstalled: Bool {
        setup.checked && setup.brew && setup.complete && setup.nginx
            && DatabaseEngine.allCases.filter(\.hasServer).allSatisfy(setup.engines.contains)
            && Runtime.allCases.allSatisfy(setup.runtimes.contains)
            && supportedPHP.allSatisfy { id in setup.phpVersions.contains { $0.id == id } }
    }

    func isRunning(_ engine: DatabaseEngine) -> Bool { runningEngines.contains(engine) }

    func isBusy(_ id: UUID) -> Bool { isBusy(id.uuidString) }
    func isBusy(_ key: String) -> Bool { busy[key, default: 0] > 0 }
    func isRunning(_ server: Server) -> Bool { runningServers.contains(server.id) }

    private func enqueue(_ key: String, _ operation: @escaping () async throws -> Void) {
        busy[key, default: 0] += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                self?.error = error.localizedDescription
            }
            self?.busy[key, default: 1] -= 1
            self?.refreshProcessState()
        }
    }

    private func refreshProcessState() {
        webServerRunning = Apache.isRunning || Nginx.isRunning
        runningEngines = Set(DatabaseEngine.allCases.filter { Services.of($0)?.isRunning == true })
        if !webServerRunning { runningServers.removeAll() }
        // A database is only on while its own server runs.
        let stopped = Set(config.databases.filter { $0.engine.hasServer && !runningEngines.contains($0.engine) }.map(\.id))
        if !stopped.isEmpty { runningDatabases.subtract(stopped) }
    }

    private func save() {
        do { try config.save() } catch { self.error = "Couldn't save settings: \(error.localizedDescription)" }
    }

    // MARK: Setup

    func refreshSetup() async {
        let fm = FileManager.default
        var status = SetupStatus()
        status.brew = Homebrew.isInstalled
        status.httpd = fm.isExecutableFile(atPath: Paths.httpd)
        status.phpVersions = PHP.installed()
        for version in status.phpVersions {
            status.phpFullVersions[version.id] = PHP.fullVersion(of: version)
        }
        status.nginx = fm.isExecutableFile(atPath: Paths.nginx)
        status.caTrusted = await Certificates.isCATrusted()
        if status.brew {
            status.brewVersion = Self.version(in: await Shell.run(Paths.brew, ["--version"]).stdout, after: "Homebrew ")
        }
        if status.httpd {
            status.httpdVersion = Self.version(in: await Shell.run(Paths.httpd, ["-v"]).stdout, after: "Apache/")
        }
        if status.nginx {
            status.nginxVersion = Self.version(in: await Shell.run(Paths.nginx, ["-v"]).output, after: "nginx/")
        }
        for engine in DatabaseEngine.allCases where engine.hasServer && engine.isInstalled {
            status.engines.insert(engine)
            status.engineVersions[engine] = await engine.version()
            status.engineFormulae[engine] = engine.installedFormula
        }
        for runtime in Runtime.allCases where runtime.isInstalled {
            status.runtimes.insert(runtime)
            status.runtimeVersions[runtime] = await runtime.version()
            status.runtimeFormulae[runtime] = runtime.installedFormula
        }
        status.helperInstalled = await Privileged.isInstalled()
        status.checked = true
        setup = status
    }

    /// Everything that setup status depends on and that can be checked without running programs.
    private func setupFingerprint() -> String {
        let fm = FileManager.default
        let files = [Paths.brew, Paths.httpd, Paths.nginx, Paths.caCert.path, Privileged.helperPath, Privileged.sudoersPath]
        let php = PHP.installed().map { "\($0.id)=\(PHP.fullVersion(of: $0) ?? "")" }
        let engines = DatabaseEngine.allCases.map(\.fingerprint)
        return (files.map { fm.fileExists(atPath: $0) ? "1" : "0" } + php + engines + Runtime.allCases.map(\.fingerprint)).joined(separator: ",")
    }

    /// Keeps Settings current while it's open: checks again whenever something was installed or removed,
    /// including outside the app (for example `brew install` in Terminal).
    func watchSetup() async {
        await refreshSetup()
        var last = setupFingerprint()
        while !Task.isCancelled {
            // Looks for new versions when Settings opens and every half hour after, without waiting for it here.
            Task { await checkForUpdates() }
            for _ in 0..<900 where !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let now = setupFingerprint()
                if now != last {
                    last = now
                    await refreshSetup()
                    await refreshOutdated()
                }
            }
        }
    }

    /// Asks Homebrew for its latest list of software, then which installed software is behind.
    /// Also asks php.net which PHP versions are still supported.
    func checkForUpdates() async {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 1500 { return }
        guard Homebrew.isInstalled, !isInstalling else { return }
        lastUpdateCheck = Date()
        if let supported = await PHP.fetchSupported() {
            supportedPHP = supported
            Paths.preferences.set(supported, forKey: "supportedPHP")
        }
        _ = await Shell.run(Paths.brew, ["update", "--quiet"])
        await refreshOutdated()
    }

    private func refreshOutdated() async {
        guard Homebrew.isInstalled else { return updates = [:] }
        let result = await Shell.run(Paths.brew, ["outdated", "--formula", "--json=v2"])
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = json["formulae"] as? [[String: Any]] else { return }
        var found: [String: String] = [:]
        for formula in formulae {
            // A formula from a tap is listed as "tap/repo/name"; Settings looks it up by its plain name.
            if let name = (formula["name"] as? String)?.split(separator: "/").last.map(String.init),
               let latest = formula["current_version"] as? String { found[name] = latest }
        }
        updates = found
    }

    /// Servers that run on this PHP version (a server without a choice uses the newest installed).
    func servers(usingPHP id: String) -> [Server] {
        config.servers.filter { ($0.phpVersion ?? PHP.newest()?.id) == id }
    }

    /// Pulls "2.4.69" out of output like "Server version: Apache/2.4.69 (Unix)".
    private static func version(in output: String, after marker: String) -> String? {
        guard let range = output.range(of: marker) else { return nil }
        return output[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
    }

    func installHomebrew() {
        enqueue("install:brew") { [weak self] in
            let tail = OutputTail()
            do {
                try await Homebrew.install { tail.append($0) }
            } catch {
                await self?.refreshSetup()
                throw ShellError("\(error.localizedDescription)\n\(tail.text)\n\nYou can also install it yourself from https://brew.sh.")
            }
            await self?.refreshSetup()
        }
    }

    func updateSoftware(formula: String, key: String) {
        enqueue("install:\(key)") { [weak self] in
            let tail = OutputTail()
            let status = await Shell.stream(Paths.brew, ["upgrade", formula]) { tail.append($0) }
            await self?.refreshSetup()
            await self?.refreshOutdated()
            if status != 0 { throw ShellError("Updating \(formula) failed (Homebrew exit \(status)).\n\(tail.text)") }
        }
    }

    /// Removes a PHP version from Homebrew. Servers that used it show "not installed" until they pick another.
    func uninstallPHP(_ version: PHP.Version) {
        enqueue("install:php@\(version.id)") { [weak self] in
            await PHPFPM.stop(version)
            let tail = OutputTail()
            let status = await Shell.stream(Paths.brew, ["uninstall", version.formula]) { tail.append($0) }
            await self?.refreshSetup()
            await self?.refreshOutdated()
            if status != 0 { throw ShellError("Removing \(version.name) failed (Homebrew exit \(status)).\n\(tail.text)") }
        }
    }

    func installApache() { install(["httpd"], key: "httpd") }
    /// Installs a database server. MySQL changes the PHP setup, so servers are applied again after it.
    func installEngine(_ engine: DatabaseEngine) {
        install(steps: engine.installCommands, name: engine.name, key: engine.rawValue, reapply: engine == .mysql)
    }
    func installNginx() { install(["nginx"], key: "nginx") }
    func installPHP(_ version: String) { install([PHP.formula(for: version)], key: "php@\(version)") }
    /// Node, Python and Ruby need no server configuration, so nothing is applied afterwards.
    func installRuntime(_ runtime: Runtime) { install([runtime.formula], key: runtime.rawValue, reapply: false) }

    /// Running servers of this kind keep using the old program, so an update waits until they're off.
    func runningServers(of runtime: Runtime) -> [Server] {
        config.servers.filter { $0.siteKind == runtime.kind && isRunning($0) }
    }

    /// Whether any software is being installed; the others' Install buttons wait for it.
    var isInstalling: Bool { busy.contains { $0.key.hasPrefix("install:") && $0.value > 0 } }

    private func install(_ formulae: [String], key: String, reapply: Bool = true) {
        install(steps: [["install"] + formulae], name: formulae.joined(separator: ", "), key: key, reapply: reapply)
    }

    /// Runs Homebrew commands one after the other, stopping at the first that fails.
    private func install(steps: [[String]], name: String, key: String, reapply: Bool = true) {
        enqueue("install:\(key)") { [weak self] in
            guard FileManager.default.isExecutableFile(atPath: Paths.brew) else {
                throw ShellError("Homebrew isn't installed. Install it in Settings first.")
            }
            let tail = OutputTail()
            for step in steps {
                let status = await Shell.stream(Paths.brew, step) { tail.append($0) }
                if status != 0 {
                    await self?.refreshSetup()
                    throw ShellError("Installing \(name) failed (`brew \(step.joined(separator: " "))` exited with \(status)).\n\(tail.text)")
                }
            }
            await self?.refreshSetup()
            if reapply { try await self?.applyServers() }
        }
    }

    func trustCertificateAuthority() {
        enqueue("ca") { [weak self] in
            try await Certificates.trustCA()
            await self?.refreshSetup()
            // Now that https:// is trusted, http:// addresses can redirect to it.
            try await self?.applyServers()
        }
    }

    func installHelper() {
        enqueue("helper") { [weak self] in
            try await Privileged.install()
            await self?.refreshSetup()
        }
    }

    // MARK: Servers

    func addServer(_ server: Server) {
        config.servers.append(server)
        config.servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        createDocumentRootIfNeeded(server)
    }

    func updateServer(_ server: Server) {
        guard let index = config.servers.firstIndex(where: { $0.id == server.id }) else { return }
        config.servers[index] = server
        save()
        createDocumentRootIfNeeded(server)
        if isRunning(server) {
            if server.webServer == .nginx && !setup.nginx {
                runningServers.remove(server.id)
                error = "Nginx isn't installed, so \(server.name) was switched off. Install Nginx in Settings, then switch it on."
            } else {
                // Apache and Nginx can't run together: a server that changed software takes the others with it.
                runningServers.subtract(runningServers(otherThan: server.webServer))
            }
            enqueue(server.id.uuidString) { [weak self] in try await self?.applyServers() }
        }
    }

    func deleteServer(_ server: Server) {
        let wasRunning = isRunning(server)
        runningServers.remove(server.id)
        config.servers.removeAll { $0.id == server.id }
        save()
        enqueue(server.id.uuidString) { [weak self] in
            if wasRunning { try await self?.applyServers() }
            Certificates.remove(for: server)
        }
    }

    func toggle(_ server: Server) {
        isRunning(server) ? stop(server) : start(server)
    }

    func start(_ server: Server) {
        enqueue(server.id.uuidString) { [weak self] in
            guard let self else { return }
            try self.requireSetup()
            if server.webServer == .nginx && !self.setup.nginx {
                throw ShellError("\(server.name) uses Nginx, which isn't installed yet. Install it in Settings, or choose Apache in the server's Edit sheet.")
            }
            self.createDocumentRootIfNeeded(server)
            try self.checkFolderAccess(server)
            // Apache and Nginx both need ports 80 and 443, so servers using the other one switch off.
            let displaced = self.runningServers(otherThan: server.webServer)
            self.runningServers.subtract(displaced)
            self.runningServers.insert(server.id)
            do {
                try await self.applyServers()
            } catch {
                self.runningServers.remove(server.id)
                self.runningServers.formUnion(displaced)
                try? await self.applyServers()
                throw error
            }
        }
    }

    func stop(_ server: Server) {
        enqueue(server.id.uuidString) { [weak self] in
            self?.runningServers.remove(server.id)
            try await self?.applyServers()
        }
    }

    /// Running servers that use the other web server.
    private func runningServers(otherThan web: WebServer) -> Set<UUID> {
        Set(config.servers.filter { runningServers.contains($0.id) && $0.webServer != web }.map(\.id))
    }

    private func requireSetup() throws {
        if !setup.packagesInstalled {
            throw ShellError("Apache, PHP and MySQL aren't installed yet. Open Settings and click Install.")
        }
        if !setup.helperInstalled {
            throw ShellError("The address helper isn't installed yet. Open Settings and install the address helper (it asks for your password once).")
        }
    }

    /// Makes the web server, PHP and /etc/hosts match `runningServers`. Apache and Nginx both need
    /// ports 80 and 443, so only the one the running servers use is started; the other is stopped.
    private func applyServers() async throws {
        let running = config.servers.filter { runningServers.contains($0.id) }
        let web = running.first?.webServer ?? .apache
        let servers = running.filter { $0.webServer == web }
        runningServers = Set(servers.map(\.id))
        guard setup.packagesInstalled else { return }

        if servers.isEmpty {
            await Apache.stop()
            await Nginx.stop()
            await PHPFPM.stopAll()
            await AppProcess.stopAll()
        } else {
            if web == .nginx && !setup.nginx { throw ShellError("Nginx isn't installed yet. Open Settings and click Install.") }
            var certificates: [UUID: Certificates.Pair] = [:]
            var phpVersions: [UUID: PHP.Version] = [:]
            for server in servers {
                certificates[server.id] = try await Certificates.ensure(for: server)
                if server.siteKind == .php { phpVersions[server.id] = try phpVersion(for: server) }
            }
            try await PHPFPM.sync(needed: Set(phpVersions.values), mysqlPort: config.mysqlPort)
            let apps = servers.filter { $0.siteKind.isApp }.map {
                AppProcess.Spec(id: $0.id, name: $0.name, command: $0.command ?? $0.siteKind.defaultCommand,
                                port: $0.port ?? $0.siteKind.defaultPort, folder: $0.documentRoot)
            }
            try await AppProcess.sync(apps) { [weak self] spec, code, output in
                Task { @MainActor in
                    self?.error = "\(spec.name) stopped on its own (exit code \(code)). Its output is in the Console.\n\n\(output)"
                }
            }
            let fallback = try await Certificates.ensureFallback()
            let sockets = phpVersions.mapValues(\.socket.path)
            switch web {
            case .apache:
                await Nginx.stop()
                let extras = Apache.Extras(fallbackCertificate: fallback, redirectToHTTPS: setup.caTrusted, phpSockets: sockets)
                try Apache.writeConfig(servers: servers, certificates: certificates, extras: extras)
                if Apache.isRunning { try await Apache.reload() } else { try await Apache.start() }
            case .nginx:
                await Apache.stop()
                let extras = Nginx.Extras(fallbackCertificate: fallback, redirectToHTTPS: setup.caTrusted, phpSockets: sockets)
                try Nginx.writeConfig(servers: servers, certificates: certificates, extras: extras)
                if Nginx.isRunning { try await Nginx.reload() } else { try await Nginx.start() }
            }
            lastWebServer = web
            WebServer.remember(web)
        }
        var hostnames = servers.flatMap(\.hostnames)
        if config.usesCustomMySQLHost && setup.helperInstalled { hostnames.append(config.mysqlHost) }
        if !hostnames.isEmpty {
            try await Privileged.setHosts(hostnames)
        } else if Privileged.hostsHasManagedBlock {
            try await Privileged.setHosts([])
        }
    }

    private func phpVersion(for server: Server) throws -> PHP.Version {
        if let version = PHP.resolve(server.phpVersion) { return version }
        if let wanted = server.phpVersion {
            throw ShellError("""
            \(server.name) uses PHP \(wanted), which isn't installed.

            Install it in Settings, or choose another PHP version in the server's Edit sheet.
            """)
        }
        throw ShellError("PHP isn't installed yet. Open Settings and click Install.")
    }

    /// Reading the folder here makes macOS ask for access to Desktop, Documents or Downloads up front
    /// (Apache inherits the app's permission) instead of the site failing with "403 Forbidden".
    private func checkFolderAccess(_ server: Server) throws {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: server.documentRoot)
        } catch {
            throw ShellError("""
            Local Hosting can't read \(server.documentRoot).

            If the folder is in Desktop, Documents or Downloads, allow access in System Settings → Privacy & Security → Files & Folders → Local Hosting, then start the server again.
            """)
        }
    }

    private func createDocumentRootIfNeeded(_ server: Server) {
        // An app server runs an existing project; there's nothing to make for it.
        guard !server.siteKind.isApp else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: server.documentRoot, isDirectory: true)
        guard !fm.fileExists(atPath: root.path) else { return }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let title = server.name.replacingOccurrences(of: "<", with: "")
            if server.siteKind == .staticSite {
                try """
                <!doctype html>
                <html lang="en">
                <head><meta charset="utf-8"><title>\(title)</title></head>
                <body style="font:16px -apple-system,sans-serif;max-width:40em;margin:4em auto;color:#333">
                  <h1>It works!</h1>
                  <p>This static site is served from This Mac by Local Hosting.</p>
                  <p>Edit <code>index.html</code> in this folder.</p>
                </body>
                </html>

                """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                return
            }
            let page = """
            <?php $host = htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'localhost'); ?>
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>\(title)</title></head>
            <body style="font:16px -apple-system,sans-serif;max-width:40em;margin:4em auto;color:#333">
              <h1>It works!</h1>
              <p>You're seeing <strong><?= $host ?></strong> served from This Mac by Local Hosting.</p>
              <p>PHP <?= PHP_VERSION ?> &middot; Edit <code>index.php</code> in <code><?= htmlspecialchars(__DIR__) ?></code></p>
            </body>
            </html>

            """
            try page.write(to: root.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        } catch {
            self.error = "Couldn't create \(root.path): \(error.localizedDescription)"
        }
    }

    func url(for server: Server) -> URL? {
        let scheme = setup.caTrusted ? "https" : "http"
        return URL(string: "\(scheme)://\(server.primaryHostname)/")
    }

    // MARK: MySQL

    // MARK: Database switches

    func isRunning(_ db: Database) -> Bool { runningDatabases.contains(db.id) }

    func toggle(_ db: Database) {
        guard db.engine.hasServer else { return }
        enqueue(db.id.uuidString) { [weak self] in
            guard let self else { return }
            let wasOn = self.runningDatabases.contains(db.id)
            if wasOn { self.runningDatabases.remove(db.id) } else { self.runningDatabases.insert(db.id) }
            do {
                try await self.applyDatabases(of: db.engine)
            } catch {
                // Put the switch back where it was.
                if wasOn { self.runningDatabases.insert(db.id) } else { self.runningDatabases.remove(db.id) }
                throw error
            }
        }
    }

    /// Makes an engine's server and each user's access match `runningDatabases`: the server runs while any of
    /// its databases is on, and only the users of databases that are on can connect.
    private func applyDatabases(of engine: DatabaseEngine) async throws {
        guard let service = Services.of(engine) else { return }
        let all = config.databases.filter { $0.engine == engine }
        let on = all.filter { runningDatabases.contains($0.id) }
        if on.isEmpty {
            await service.stop()
            return
        }
        guard setup.isInstalled(engine) else {
            throw ShellError("\(engine.name) isn't installed yet. Open Settings and click Install.")
        }
        if !service.isRunning { try await service.start(port: config.port(for: engine)) }
        try await service.applyAccess(all: all, on: on)
    }

    /// Runs work that needs an engine's server even while all its databases are off, then puts things back.
    private func withService(_ engine: DatabaseEngine, _ work: (any DatabaseService) async throws -> Void) async throws {
        guard let service = Services.of(engine) else { return }
        guard setup.isInstalled(engine) else {
            throw ShellError("\(engine.name) isn't installed yet. Open Settings and click Install.")
        }
        let wasRunning = service.isRunning
        if !wasRunning { try await service.start(port: config.port(for: engine)) }
        defer {
            if !wasRunning && !config.databases.contains(where: { $0.engine == engine && runningDatabases.contains($0.id) }) {
                Task { await service.stop() }
            }
        }
        try await work(service)
    }

    // MARK: Passwords

    func validatePassword(_ password: String) -> String? {
        if password.isEmpty { return "The password can't be empty." }
        if password.contains(where: \.isNewline) { return "The password can't contain line breaks." }
        return nil
    }

    /// A new database starts switched on, ready for its project to connect.
    func addDatabase(_ db: Database) {
        var db = db
        if db.engine == .redis {
            // A Redis database is a number: the first one nobody has.
            let taken = Set(config.databases.compactMap { $0.engine == .redis ? $0.index : nil })
            guard let free = (0..<RedisService.databaseCount).first(where: { !taken.contains($0) }) else {
                error = "Redis has \(RedisService.databaseCount) databases and all of them are in use. Delete one first."
                return
            }
            db.index = free
        }
        enqueue(db.engine.rawValue) { [weak self] in
            guard let self else { return }
            let engine = db.engine
            if engine == .sqlite {
                try FileManager.default.createDirectory(at: Paths.sqliteDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: db.file.path) {
                    throw ShellError("A file named \(db.file.lastPathComponent) is already in the SQLite folder.")
                }
                // An empty file is a valid, empty SQLite database.
                FileManager.default.createFile(atPath: db.file.path, contents: nil)
            } else {
                guard self.setup.isInstalled(engine), let service = Services.of(engine) else {
                    throw ShellError("\(engine.name) isn't installed yet. Open Settings and click Install.")
                }
                // The new database starts on, so its server stays up afterwards.
                if !service.isRunning { try await service.start(port: self.config.port(for: engine)) }
                var created = db
                // Every Redis database shows the server's one password, which exists once the server has run.
                if engine == .redis { created.password = RedisService.password ?? "" }
                do {
                    try await service.create(created)
                } catch {
                    if !self.config.databases.contains(where: { $0.engine == engine && self.runningDatabases.contains($0.id) }) {
                        await service.stop()
                    }
                    throw error
                }
                db = created
            }
            self.config.databases.append(db)
            if engine.hasServer { self.runningDatabases.insert(db.id) }
            self.config.databases.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // A user shared by several databases has one password; keep every entry in sync.
            if engine.hasAccounts {
                for i in self.config.databases.indices where self.config.databases[i].engine == engine && self.config.databases[i].username == db.username {
                    self.config.databases[i].password = db.password
                }
            }
            self.save()
            try await self.applyDatabases(of: engine)
        }
    }

    func changePassword(_ db: Database, to password: String) {
        guard db.engine.hasAccounts else { return }
        enqueue(db.engine.rawValue) { [weak self] in
            guard let self else { return }
            try await self.withService(db.engine) { try await $0.setPassword(username: db.username, password: password) }
            for i in self.config.databases.indices where self.config.databases[i].engine == db.engine && self.config.databases[i].username == db.username {
                self.config.databases[i].password = password
            }
            self.save()
        }
    }

    func deleteDatabase(_ db: Database) {
        enqueue(db.engine.rawValue) { [weak self] in
            guard let self else { return }
            if db.engine == .sqlite {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: db.file.path + suffix)
                }
            } else {
                let userStillUsed = self.config.databases.contains { $0.id != db.id && $0.engine == db.engine && $0.username == db.username }
                try await self.withService(db.engine) { try await $0.drop(db, dropUser: !userStillUsed) }
            }
            self.config.databases.removeAll { $0.id == db.id }
            self.runningDatabases.remove(db.id)
            self.save()
            if let service = Services.of(db.engine),
               !self.config.databases.contains(where: { $0.engine == db.engine && self.runningDatabases.contains($0.id) }) {
                await service.stop()
            }
        }
    }

    // MARK: Lifecycle

    /// Stops processes left behind by a crash and restores /etc/hosts.
    private func cleanUpLeftovers() async {
        await Apache.stop()
        await Leftovers.stop(usingConfig: Paths.httpdConf)
        await Nginx.stop()
        await PHPFPM.stopAll()
        await AppProcess.stopLeftovers()
        // Every database starts switched off, like every server, so the database servers start stopped too.
        for engine in DatabaseEngine.allCases {
            guard let service = Services.of(engine) else { continue }
            await service.stop()
            await service.stopLeftovers()
        }
        if Privileged.hostsHasManagedBlock, await Privileged.isInstalled() {
            try? await Privileged.setHosts([])
        }
    }

    /// Called on quit: everything goes back to normal, so real domains resolve to the internet again.
    func stopEverything() async {
        runningServers.removeAll()
        await Apache.stop()
        await Nginx.stop()
        await PHPFPM.stopAll()
        await AppProcess.stopAll()
        for engine in DatabaseEngine.allCases { await Services.of(engine)?.stop() }
        if Privileged.hostsHasManagedBlock {
            try? await Privileged.setHosts([])
        }
        refreshProcessState()
    }

    // MARK: Table browser

    /// Opens a database in the Browser, switching it on first if needed.
    func browse(_ database: String) {
        if let db = config.databases.first(where: { $0.name == database }), !isRunning(db) { toggle(db) }
        browseRequest = database
        navigationRequest = .browser
    }

    /// Earlier versions served a dashboard at https://localhost; it now lives in the app.
    private func removeOldWebDashboard() {
        for name in ["dashboard", "dashboard.json"] {
            try? FileManager.default.removeItem(at: Paths.support.appendingPathComponent(name))
        }
    }

    func openInBrowser(_ server: Server) {
        if let url = url(for: server) { NSWorkspace.shared.open(url) }
    }

    func revealDocumentRoot(_ server: Server) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.documentRoot)])
    }
}

/// Keeps the last lines a command printed, so a failure can show why.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 12 { lines.removeFirst() }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
