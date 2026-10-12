import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }

    var output: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct ShellError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Shell {
    /// Environment for child processes: GUI apps start with a minimal PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Paths.brewPrefix)/bin:\(Paths.brewPrefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    static func run(_ executable: String, _ arguments: [String] = [], input: String? = nil,
                    environment extra: [String: String] = [:]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(executable, arguments, input: input, environment: extra))
            }
        }
    }

    /// Runs and throws with the command's output when it exits non-zero.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String] = [], input: String? = nil,
                      environment extra: [String: String] = [:], what: String) async throws -> ShellResult {
        let result = await run(executable, arguments, input: input, environment: extra)
        guard result.ok else {
            throw ShellError("\(what) failed (exit \(result.status)).\n\(result.output)")
        }
        return result
    }

    static func runSync(_ executable: String, _ arguments: [String], input: String? = nil,
                        environment extra: [String: String] = [:]) -> ShellResult {
        // Output goes to temp files instead of pipes: daemons (httpd, mysqld) inherit the
        // descriptors, and a pipe held open by a daemon would never reach end-of-file.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("localhosting-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ShellResult(status: -1, stdout: "", stderr: "Could not create temporary files.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(extra) { _, new in new }
        process.standardOutput = outHandle
        process.standardError = errHandle
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "Could not run \(executable): \(error.localizedDescription)")
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ShellResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Runs a long command, reporting each output line as it arrives (used for `brew install`).
    static func stream(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:],
                       onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment.merging(extra) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    buffer.append(data)
                }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                buffer.flush()
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                onLine("Could not run \(executable): \(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }
    }
}

final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            onLine(String(decoding: line, as: UTF8.self))
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
    }
}
