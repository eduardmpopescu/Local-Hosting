import Foundation

/// One reply from Redis, in its own protocol's terms.
enum RedisReply: Sendable {
    case status(String)
    case error(String)
    case integer(Int)
    case bulk(String?)
    case array([RedisReply]?)

    /// The reply as the text of a single cell.
    var text: String? {
        switch self {
        case .status(let s), .error(let s): s
        case .integer(let n): String(n)
        case .bulk(let s): s
        case .array(let items): items.map { "[" + $0.map { $0.text ?? "nil" }.joined(separator: ", ") + "]" }
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

/// A blocking connection to Redis over TCP on this Mac. Every call takes a short time on localhost,
/// so it is always used from a background queue (see `RedisService.connect`).
final class RedisConnection {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var position = 0

    init(port: Int, password: String?, database: Int?) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShellError("Couldn't open a connection to Redis.") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw ShellError("Redis isn't answering on port \(port).")
        }
        do {
            if let password, let message = try command(["AUTH", password]).errorMessage { throw ShellError("Redis refused the password: \(message)") }
            if let database, let message = try command(["SELECT", String(database)]).errorMessage { throw ShellError(message) }
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(fd) }

    func command(_ arguments: [String]) throws -> RedisReply {
        try pipeline([arguments])[0]
    }

    /// Sends every command at once, then reads every reply: one round trip for any number of commands.
    func pipeline(_ commands: [[String]]) throws -> [RedisReply] {
        var out = Data()
        for arguments in commands {
            out.append(Data("*\(arguments.count)\r\n".utf8))
            for argument in arguments {
                let bytes = Data(argument.utf8)
                out.append(Data("$\(bytes.count)\r\n".utf8))
                out.append(bytes)
                out.append(Data("\r\n".utf8))
            }
        }
        try write(out)
        return try commands.map { _ in try readReply() }
    }

    private func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < data.count {
                let n = send(fd, raw.baseAddress! + sent, data.count - sent, 0)
                guard n > 0 else { throw ShellError("Lost the connection to Redis.") }
                sent += n
            }
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { throw ShellError("Redis stopped answering.") }
        if position > 1 << 20 {
            buffer.removeFirst(position)
            position = 0
        }
        buffer.append(contentsOf: chunk[0..<n])
    }

    private func readLine() throws -> String {
        while true {
            if let end = buffer[position...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[position..<max(position, end - 1)], as: UTF8.self)
                position = end + 1
                return line
            }
            try fill()
        }
    }

    private func readBytes(_ count: Int) throws -> [UInt8] {
        while buffer.count - position < count + 2 { try fill() }
        let bytes = Array(buffer[position..<position + count])
        position += count + 2
        return bytes
    }

    private func readReply() throws -> RedisReply {
        let line = try readLine()
        guard let kind = line.first else { throw ShellError("Redis sent something unexpected.") }
        let rest = String(line.dropFirst())
        switch kind {
        case "+": return .status(rest)
        case "-": return .error(rest)
        case ":": return .integer(Int(rest) ?? 0)
        case "$":
            guard let length = Int(rest), length >= 0 else { return .bulk(nil) }
            return .bulk(String(decoding: try readBytes(length), as: UTF8.self))
        case "*":
            guard let count = Int(rest), count >= 0 else { return .array(nil) }
            return .array(try (0..<count).map { _ in try readReply() })
        default: throw ShellError("Redis sent something unexpected.")
        }
    }
}

/// A private Redis server. Its databases are numbered, 0 to 15, and share one password: Redis has no
/// separate accounts per database.
struct RedisService: DatabaseService {
    static let databaseCount = 16

    static var password: String? {
        (try? String(contentsOf: Paths.redisPassword, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The port in the generated config.
    static var port: Int? {
        fileLines(at: Paths.redisConf)?.compactMap { line -> Int? in
            line.hasPrefix("port ") ? Int(line.dropFirst(5)) : nil
        }.first
    }

    var isRunning: Bool { runningPid(at: Paths.redisPid) != nil }
    var pid: pid_t? { runningPid(at: Paths.redisPid) }

    func start(port: Int) async throws {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.redisServer) else {
            throw ShellError("Redis isn't installed yet. Open Settings and click Install.")
        }
        await stopLeftovers()
        try await Ports.ensureFree(port, for: "Redis", hint: "If it's another Redis, stop it (for example: brew services stop redis).")
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.redisData, withIntermediateDirectories: true)
        let password = Self.password ?? Database.generatePassword(length: 24)
        if Self.password == nil { try writePrivate(password, to: Paths.redisPassword) }
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try writePrivate("""
        # Generated by Local Hosting.
        bind 127.0.0.1
        port \(port)
        daemonize yes
        pidfile "\(Paths.redisPid.path)"
        logfile "\(Paths.redisLog.path)"
        dir "\(Paths.redisData.path)"
        requirepass "\(escaped)"
        databases \(Self.databaseCount)
        save 900 1
        save 300 100
        save 60 10000
        appendonly no
        """, to: Paths.redisConf)

        let result = await Shell.run(Paths.redisServer, [Paths.redisConf.path])
        guard result.ok, await waitUntilReady(port: port, password: password) else {
            throw ShellError("Redis did not start.\n\(result.output)\n\(Self.tailOfLog())")
        }
    }

    private func waitUntilReady(port: Int, password: String) async -> Bool {
        for _ in 0..<40 {
            let ready = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let reply = (try? RedisConnection(port: port, password: password, database: nil))
                        .flatMap { try? $0.command(["PING"]) }
                    continuation.resume(returning: reply?.text == "PONG")
                }
            }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// SIGTERM makes Redis save its data and shut down.
    func stop() async {
        guard let pid = runningPid(at: Paths.redisPid) else { return }
        kill(pid, SIGTERM)
        await waitForExit(of: pid)
    }

    func stopLeftovers() async { await Leftovers.stop(usingConfig: Paths.redisConf) }

    /// Runs commands on a connection to one of the databases, off the main thread.
    static func connect<T>(database: Int? = nil, _ body: @escaping (RedisConnection) throws -> T) async throws -> T {
        guard let port, let password else { throw ShellError("Redis isn't running.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let connection = try RedisConnection(port: port, password: password, database: database)
                    continuation.resume(returning: try body(connection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func create(_ db: Database) async throws {}

    /// Removing a database empties its number.
    func drop(_ db: Database, dropUser: Bool) async throws {
        guard let index = db.index else { return }
        try await Self.connect(database: index) { connection in
            if let message = try connection.command(["FLUSHDB"]).errorMessage { throw ShellError(message) }
        }
    }

    func setPassword(username: String, password: String) async throws {}

    /// The server has one account for every database, so there's nothing to lock per database.
    func applyAccess(all: [Database], on: [Database]) async throws {}

    static func tailOfLog(lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: Paths.redisLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
