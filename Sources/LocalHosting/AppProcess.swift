import Foundation

/// The Node, Python and Ruby processes behind app servers. Each runs the server's start command in the
/// project folder, in its own process group so stopping it also stops whatever it started.
/// Output goes to the shared apps log, every line starting with the server's name.
enum AppProcess {
    struct Spec: Equatable {
        let id: UUID
        let name: String
        let command: String
        let port: Int
        let folder: String
    }

    private final class Running: @unchecked Sendable {
        let pid: pid_t
        let spec: Spec
        /// Kept for as long as the process runs: closing its read end would break the app's own output.
        let output: Pipe
        let tail = OutputTail()
        var stopping = false
        var notify = false
        init(pid: pid_t, spec: Spec, output: Pipe) { self.pid = pid; self.spec = spec; self.output = output }
    }

    private static let lock = NSLock()
    private static var running: [UUID: Running] = [:]
    private static let logQueue = DispatchQueue(label: "localhosting.apps.log")

    /// The process id of a running app server, whose process group holds everything it started.
    static func pid(of id: UUID) -> pid_t? {
        lock.withLock { running[id]?.pid }
    }

    static func isRunning(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running[id] != nil
    }

    /// Makes the running processes match `specs`: starts the missing ones, restarts those whose
    /// command, port or folder changed, and stops the rest. `onExit` hears about a process that dies on its own.
    static func sync(_ specs: [Spec], onExit: @escaping @Sendable (Spec, Int32, String) -> Void) async throws {
        let wanted = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        let current = lock.withLock { running.mapValues(\.spec) }
        for (id, spec) in current where wanted[id] != spec {
            await stop(id)
        }
        for spec in specs where !isRunning(spec.id) {
            try await start(spec, onExit: onExit)
        }
    }

    private static func start(_ spec: Spec, onExit: @escaping @Sendable (Spec, Int32, String) -> Void) async throws {
        try await Ports.ensureFree(spec.port, for: spec.name, hint: """
        Something else is already listening on port \(spec.port). Stop it, or give \(spec.name) a different port in its Edit sheet.
        """)
        appendLog("[\(spec.name)] Starting: \(spec.command) (port \(spec.port))")

        var env = Shell.environment
        env["PORT"] = String(spec.port)
        env["PYTHONUNBUFFERED"] = "1"
        env["BROWSER"] = "none"
        // Left over when the app was started from Terminal; they make the shell print session messages.
        env.removeValue(forKey: "TERM_PROGRAM")
        env.removeValue(forKey: "TERM_SESSION_ID")
        // The token only marks the process, so one we lost track of can be found and stopped. The second
        // line keeps zsh around: otherwise it replaces itself with the command and the token is lost.
        let argv = ["/bin/zsh", "-ilc", Runtime.pathSetup + "\n" + spec.command + "\nexit $?", token(for: spec.id)]
        let pipe = Pipe()
        let pid = try spawn(argv, environment: env, folder: spec.folder, output: pipe)
        let process = Running(pid: pid, spec: spec, output: pipe)
        lock.withLock { running[spec.id] = process }

        let lines = LineBuffer { line in
            process.tail.append(line)
            appendLog("[\(spec.name)] \(line)")
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.append(data) }
        }
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            process.output.fileHandleForReading.readabilityHandler = nil
            lines.flush()
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            let (stopped, notify) = lock.withLock { () -> (Bool, Bool) in
                if running[spec.id] === process { running[spec.id] = nil }
                return (process.stopping, process.notify)
            }
            appendLog("[\(spec.name)] Stopped (exit \(code))")
            if !stopped && notify { onExit(spec, code, process.tail.text) }
        }

        // A command that fails at once (not found, wrong folder) should say so now, not leave a dead site.
        try await Task.sleep(nanoseconds: 900_000_000)
        guard isRunning(spec.id) else {
            throw ShellError("\(spec.name) stopped right after starting.\n\n\(process.tail.text)")
        }
        lock.withLock { process.notify = true }
    }

    static func stop(_ id: UUID) async {
        guard let process = lock.withLock({ () -> Running? in
            guard let process = running[id] else { return nil }
            process.stopping = true
            return process
        }) else { return }
        kill(-process.pid, SIGTERM)
        for _ in 0..<50 where isRunning(id) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isRunning(id) {
            kill(-process.pid, SIGKILL)
            for _ in 0..<20 where isRunning(id) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    static func stopAll() async {
        for id in lock.withLock({ Array(running.keys) }) { await stop(id) }
    }

    /// Stops app processes left behind by a crash. Only those started from this data folder.
    static func stopLeftovers() async {
        let result = await Shell.run("/usr/bin/pgrep", ["-f", "--", NSRegularExpression.escapedPattern(for: tokenPrefix)])
        for pid in result.stdout.split(separator: "\n").compactMap({ pid_t($0) }) where pid != getpid() {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
        }
    }

    // MARK: Internals

    private static var tokenPrefix: String {
        // A stable short hash of the data folder, so a test run never touches the real app's processes.
        var hash: UInt32 = 5381
        for byte in Paths.support.path.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return "localhosting-app-\(String(hash, radix: 16))-"
    }

    private static func token(for id: UUID) -> String { tokenPrefix + id.uuidString }

    private static func appendLog(_ text: String) {
        logQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Paths.appsDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: Paths.appsLog.path) { fm.createFile(atPath: Paths.appsLog.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: Paths.appsLog) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    private static func spawn(_ argv: [String], environment: [String: String], folder: String, output: Pipe) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group (the child's own pid), so everything it starts can be stopped together.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let write = output.fileHandleForWriting.fileDescriptor
        let read = output.fileHandleForReading.fileDescriptor
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, write, 1)
        posix_spawn_file_actions_adddup2(&actions, write, 2)
        posix_spawn_file_actions_addclose(&actions, read)
        posix_spawn_file_actions_addclose(&actions, write)
        posix_spawn_file_actions_addchdir_np(&actions, folder)

        let args = argv.map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            args.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, argv[0], &actions, &attributes, args, env)
        // The child has its own copy of the write end; ours must close or the reader never sees the end.
        try? output.fileHandleForWriting.close()
        guard status == 0 else {
            throw ShellError("Couldn't start the process: \(String(cString: strerror(status))).")
        }
        return pid
    }
}
