import Foundation

/// The PHP versions Homebrew has installed. Each one runs as its own PHP-FPM process,
/// so servers can use different versions side by side.
enum PHP {
    struct Version: Hashable, Identifiable {
        /// Major and minor, e.g. "8.3".
        let id: String
        /// The Homebrew folder under opt, e.g. "php" or "php@8.3".
        let folder: String

        var name: String { "PHP \(id)" }
        /// The Homebrew formula behind the install: "php" for the newest, "php@8.3" for older ones.
        var formula: String {
            URL(fileURLWithPath: prefix).resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent
        }
        var prefix: String { "\(Paths.brewPrefix)/opt/\(folder)" }
        var fpm: String { "\(prefix)/sbin/php-fpm" }
        var cli: String { "\(prefix)/bin/php" }

        /// Where this version's FPM keeps its config, pid and socket.
        var config: URL { Paths.phpDir.appendingPathComponent("\(id).conf") }
        var pidFile: URL { Paths.phpRun.appendingPathComponent("\(id).pid") }
        var socket: URL { Paths.phpRun.appendingPathComponent("\(id).sock") }
    }

    /// Versions offered when php.net can't be reached and none were saved from an earlier visit.
    static let fallbackSupported = ["8.5", "8.4", "8.3", "8.2"]

    /// The versions php.net says still get fixes, newest first; nil when it can't be reached.
    static func fetchSupported() async -> [String]? {
        let result = await Shell.run("/usr/bin/curl", ["-fsS", "-m", "15", "https://www.php.net/releases/active.php"])
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        let ids = json.values.flatMap(\.keys)
            .filter { $0.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil }
        guard !ids.isEmpty else { return nil }
        return ids.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// The Homebrew formula to install for a version. `php@8.5` is an alias of the main `php` formula.
    static func formula(for id: String) -> String { "php@\(id)" }

    /// Installed versions, newest first.
    static func installed() -> [Version] {
        let fm = FileManager.default
        let opt = "\(Paths.brewPrefix)/opt"
        let folders = ((try? fm.contentsOfDirectory(atPath: opt)) ?? []).filter { $0 == "php" || $0.hasPrefix("php@") }
        var found: [String: Version] = [:]
        for folder in folders {
            guard fm.isExecutableFile(atPath: "\(opt)/\(folder)/sbin/php-fpm"),
                  let id = versionID(ofFolder: "\(opt)/\(folder)") else { continue }
            // `php` and its `php@x.y` alias point at the same install; keep the first.
            if found[id] == nil { found[id] = Version(id: id, folder: folder) }
        }
        return found.values.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
    }

    static func newest() -> Version? { installed().first }

    /// The version a server uses: its own choice, or the newest installed.
    static func resolve(_ id: String?) -> Version? {
        let all = installed()
        guard let id else { return all.first }
        return all.first { $0.id == id }
    }

    /// "8.5" from a Homebrew folder that resolves to .../Cellar/php/8.5.11_1.
    private static func versionID(ofFolder path: String) -> String? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().lastPathComponent
        let parts = target.split(separator: ".")
        guard parts.count >= 2, Int(parts[0]) != nil, Int(parts[1].prefix { $0.isNumber }) != nil else { return nil }
        return "\(parts[0]).\(parts[1].prefix { $0.isNumber })"
    }

    /// "8.5.11" for the version's full number.
    static func fullVersion(of version: Version) -> String? {
        let target = URL(fileURLWithPath: version.prefix).resolvingSymlinksInPath().lastPathComponent
        // Drops Homebrew's revision suffix, "8.5.11_1" -> "8.5.11".
        return target.split(separator: "_").first.map(String.init)
    }
}

/// One PHP-FPM process per version, started while a server that uses it is on.
enum PHPFPM {
    static func isRunning(_ version: PHP.Version) -> Bool { runningPid(at: version.pidFile) != nil }

    /// Makes the running FPM processes match `needed`: starts the missing ones, restarts those whose
    /// settings changed, and stops the rest.
    static func sync(needed: Set<PHP.Version>, mysqlPort: Int) async throws {
        for version in PHP.installed() where !needed.contains(version) {
            await stop(version)
        }
        for version in needed {
            let changed = try writeConfig(for: version, mysqlPort: mysqlPort)
            if isRunning(version) {
                if changed {
                    await stop(version)
                    try await start(version)
                }
            } else {
                try await start(version)
            }
        }
    }

    /// Writes the config; returns whether it differs from what was there.
    private static func writeConfig(for version: PHP.Version, mysqlPort: Int) throws -> Bool {
        try FileManager.default.createDirectory(at: Paths.phpRun, withIntermediateDirectories: true)
        if version.socket.path.utf8.count > 103 {
            throw ShellError("The PHP socket path is too long for macOS: \(version.socket.path)")
        }
        let conf = """
        ; Generated by Local Hosting.
        [global]
        pid = "\(version.pidFile.path)"
        error_log = "\(Paths.phpLog.path)"
        daemonize = yes

        [www]
        listen = "\(version.socket.path)"
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 12
        pm.process_idle_timeout = 20s
        catch_workers_output = yes
        decorate_workers_output = no
        php_admin_flag[log_errors] = on
        php_admin_value[error_log] = "\(Paths.phpLog.path)"
        php_admin_value[mysqli.default_socket] = "\(Paths.mysqlSocket.path)"
        php_admin_value[pdo_mysql.default_socket] = "\(Paths.mysqlSocket.path)"
        php_admin_value[mysqli.default_port] = \(mysqlPort)
        php_value[upload_max_filesize] = 256M
        php_value[post_max_size] = 256M
        php_value[memory_limit] = 512M

        """
        let existing = try? String(contentsOf: version.config, encoding: .utf8)
        guard existing != conf else { return false }
        try conf.write(to: version.config, atomically: true, encoding: .utf8)
        return true
    }

    private static func start(_ version: PHP.Version) async throws {
        // A PHP-FPM of ours that we lost track of (crash, deleted pid file) still owns the socket.
        await Leftovers.stop(usingConfig: version.config)
        try? FileManager.default.removeItem(at: version.socket)
        let result = await Shell.run(version.fpm, ["--fpm-config", version.config.path])
        for _ in 0..<40 where !isRunning(version) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard result.ok, isRunning(version) else {
            throw ShellError("\(version.name) did not start.\n\(result.output)\n\(tailOfLog())")
        }
    }

    static func stop(_ version: PHP.Version) async {
        if let pid = runningPid(at: version.pidFile) {
            kill(pid, SIGQUIT)
            for _ in 0..<50 where kill(pid, 0) == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        await Leftovers.stop(usingConfig: version.config)
        try? FileManager.default.removeItem(at: version.pidFile)
        try? FileManager.default.removeItem(at: version.socket)
    }

    static func stopAll() async {
        for version in PHP.installed() { await stop(version) }
        // A version uninstalled since it started leaves its process behind.
        await Leftovers.stop(usingConfig: Paths.phpDir)
    }

    static func tailOfLog(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: Paths.phpLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
