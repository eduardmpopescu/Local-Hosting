import Foundation

enum Ports {
    /// Whether anything accepts connections on the port. Connecting (rather than test-binding)
    /// also sees listeners owned by root, and isn't fooled by closed connections that linger
    /// for a minute after a server stops.
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result != 0
    }

    /// Describes who is listening on the port, e.g. "mysqld (pid 123)", when that's visible.
    static func owner(of port: Int) async -> String? {
        let result = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        var pid: String?
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), let pid { return "\(line.dropFirst()) (pid \(pid))" }
        }
        return nil
    }

    static func ensureFree(_ port: Int, for service: String, hint: String) async throws {
        guard !isFree(port) else { return }
        let who = await owner(of: port).map { "\($0) is" } ?? "Another program is"
        throw ShellError("\(who) already using port \(port), so \(service) can't start.\n\n\(hint)")
    }
}

enum Leftovers {
    /// Processes started from our config file that we've lost track of, e.g. after a crash
    /// or after their pid file was deleted.
    static func pids(usingConfig config: URL) async -> [pid_t] {
        let result = await Shell.run("/usr/bin/pgrep", ["-f", "--", NSRegularExpression.escapedPattern(for: config.path)])
        return result.stdout.split(separator: "\n").compactMap { pid_t($0) }.filter { $0 != getpid() }
    }

    /// Asks the processes to shut down cleanly, forcing them only if they don't.
    static func stop(usingConfig config: URL) async {
        let pids = await pids(usingConfig: config)
        guard !pids.isEmpty else { return }
        pids.forEach { kill($0, SIGTERM) }
        for _ in 0..<150 where pids.contains(where: { kill($0, 0) == 0 }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        pids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }
}
