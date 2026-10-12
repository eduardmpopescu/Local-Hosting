import AppKit
import Darwin
import Foundation

/// How much memory processes hold, read straight from the system: no program is started, so it's cheap
/// enough to ask every second.
enum ProcessMemory {
    /// Memory in bytes held by a process and everything it started (a server and its workers).
    static func tree(_ root: pid_t) -> Int {
        var total = 0
        var pending = [root]
        var seen: Set<pid_t> = []
        while let pid = pending.popLast(), seen.insert(pid).inserted {
            total += resident(pid)
            pending += children(of: pid)
        }
        return total
    }

    /// Memory in bytes held by every process in a process group (an app server and all it started).
    static func group(_ group: pid_t) -> Int {
        var buffer = [pid_t](repeating: 0, count: 1024)
        let count = Int(proc_listpgrppids(group, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
        return buffer.prefix(max(0, min(count, buffer.count))).filter { $0 > 0 }.reduce(0) { $0 + resident($1) }
    }

    private static func resident(_ pid: pid_t) -> Int {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        return size == Int32(MemoryLayout<proc_taskinfo>.size) ? Int(info.pti_resident_size) : 0
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let count = Int(proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
        return buffer.prefix(max(0, min(count, buffer.count))).filter { $0 > 0 }
    }
}

/// How much memory each running server and database uses, and how much room the open one takes on disk. Memory is
/// read every second, and disk use for the server or database being looked at only; both pause while the app is in
/// the background. Disk figures are remembered between launches.
@MainActor
final class ResourceMonitor: ObservableObject {
    private static let storageKey = "storageSizes"

    /// What a page is looking at, so only that has its disk use measured.
    enum Focus {
        case server(Server)
        case database(Database)
    }

    /// Memory in bytes, by server or database id. Missing while it isn't running.
    @Published private(set) var memory: [UUID: Int] = [:]
    /// Disk use in bytes, by server or database id.
    @Published private(set) var storage: [UUID: Int64]

    init() {
        let saved = Paths.preferences.dictionary(forKey: Self.storageKey) as? [String: Int] ?? [:]
        storage = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, Int64(value)) } })
    }

    /// Keeps the figures current for as long as the calling page is open.
    func watch(_ state: AppState, focus: Focus?) async {
        async let memoryLoop: Void = watchMemory(state)
        async let storageLoop: Void = watchStorage(state, focus: focus)
        _ = await (memoryLoop, storageLoop)
    }

    private func watchMemory(_ state: AppState) async {
        while !Task.isCancelled {
            if NSApp.isActive { refreshMemory(state) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func watchStorage(_ state: AppState, focus: Focus?) async {
        guard let focus else { return }
        while !Task.isCancelled {
            let started = Date()
            if NSApp.isActive { await refreshStorage(of: focus, state: state) }
            // Slower for what costs more to measure (a big folder, a MongoDB shell), so it never keeps the Mac busy.
            let took = Date().timeIntervalSince(started)
            try? await Task.sleep(nanoseconds: UInt64(max(2, took * 8) * 1_000_000_000))
        }
    }

    // MARK: Memory

    func refreshMemory(_ state: AppState) {
        var found: [UUID: Int] = [:]
        let apache = runningPid(at: Paths.apachePid).map { ProcessMemory.tree($0) }
        let nginx = runningPid(at: Paths.nginxPid).map { ProcessMemory.tree($0) }
        var php: [String: Int] = [:]
        for version in PHP.installed() {
            if let pid = runningPid(at: version.pidFile) { php[version.id] = ProcessMemory.tree(pid) }
        }
        for server in state.config.servers where state.isRunning(server) {
            switch server.siteKind {
            case .node, .python, .ruby:
                if let pid = AppProcess.pid(of: server.id) { found[server.id] = ProcessMemory.group(pid) }
            case .php, .staticSite:
                // These are served by the web server (and PHP) that every site on it shares.
                var bytes = (server.webServer == .nginx ? nginx : apache) ?? 0
                if server.siteKind == .php, let id = server.phpVersion ?? PHP.newest()?.id { bytes += php[id] ?? 0 }
                found[server.id] = bytes
            }
        }

        // A database server is one process for all of its databases.
        var engineMemory: [DatabaseEngine: Int] = [:]
        for engine in DatabaseEngine.allCases {
            if let pid = Services.of(engine)?.pid { engineMemory[engine] = ProcessMemory.tree(pid) }
        }
        for db in state.config.databases where state.isRunning(db) {
            if let bytes = engineMemory[db.engine] { found[db.id] = bytes }
        }
        // To the nearest quarter of a megabyte, so the figure moves when memory really does.
        found = found.mapValues { $0 / 262_144 * 262_144 }
        if found != memory { memory = found }
    }

    // MARK: Disk

    /// Measures one server's or database's disk use.
    func refreshStorage(of focus: Focus, state: AppState) async {
        switch focus {
        case .server(let server):
            if let size = await Self.folderSize(server.documentRoot) { set(server.id, size) }
        case .database(let db):
            if let size = await size(of: db, state: state) { set(db.id, size) }
        }
        remember()
    }

    private func size(of db: Database, state: AppState) async -> Int64? {
        switch db.engine {
        case .mysql:
            return await Self.folderSize(Paths.mysqlData.appendingPathComponent(db.name).path)
        case .sqlite:
            return Self.fileSize(db.file.path) + Self.fileSize(db.file.path + "-wal")
        case .redis:
            return Self.fileSize(Paths.redisData.appendingPathComponent("dump.rdb").path)
        case .postgresql:
            // It can only be asked while it runs.
            guard state.isRunning(db),
                  let outcome = try? await PostgresEngine().run("SELECT pg_database_size(\(SQLQuote.literal(db.name)));", in: "postgres", limit: 1),
                  let text = outcome.results.first?.rows?.first?.first.flatMap({ $0 }) else { return nil }
            return Int64(text)
        case .mongodb:
            guard state.isRunning(db),
                  let output = try? await Mongosh.run("""
                  const found = db.adminCommand({ listDatabases: 1 }).databases.find(d => d.name === \(Mongosh.literal(db.name)));
                  print(found ? (typeof found.sizeOnDisk.toNumber === 'function' ? found.sizeOnDisk.toNumber() : Number(found.sizeOnDisk)) : 0);
                  """),
                  let line = output.split(whereSeparator: \.isNewline).last, let bytes = Double(line) else { return nil }
            // A database nothing has been stored in isn't in MongoDB's list yet: it takes no room.
            return Int64(bytes)
        }
    }

    private func set(_ id: UUID, _ size: Int64) {
        if storage[id] != size { storage[id] = size }
    }

    private func remember() {
        Paths.preferences.set(Dictionary(uniqueKeysWithValues: storage.map { ($0.key.uuidString, Int($0.value)) }), forKey: Self.storageKey)
    }

    /// The size of a folder and everything in it, from `du`.
    private static func folderSize(_ path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let result = await Shell.run("/usr/bin/du", ["-sk", path])
        guard let kilobytes = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ Int64($0) }) else { return nil }
        return kilobytes * 1024
    }

    private static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
    }
}
