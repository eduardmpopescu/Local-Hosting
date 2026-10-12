import Foundation

/// Installing Homebrew itself, with Homebrew's own installer.
enum Homebrew {
    private static let scripts = "https://raw.githubusercontent.com/Homebrew/install/HEAD"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.brew) }

    /// Homebrew's installer. It installs the Xcode Command Line Tools first if they're missing.
    static func install(onLine: @escaping @Sendable (String) -> Void) async throws {
        try await run("install.sh", what: "Installing Homebrew", onLine: onLine)
    }

    /// The installer needs an administrator password but runs without a terminal, so `sudo` is pointed at a
    /// small password dialog (SUDO_ASKPASS), and the script is told not to wait for key presses.
    private static func run(_ script: String, what: String,
                            onLine: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("localhosting-brew-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent(script)
        try await Shell.check("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", file.path, "\(scripts)/\(script)"],
                              what: "Downloading Homebrew's \(script)")

        let askpass = dir.appendingPathComponent("askpass")
        try """
        #!/bin/bash
        /usr/bin/osascript <<'APPLESCRIPT'
        tell me to activate
        set answer to display dialog "Local Hosting needs your password to install Homebrew." default answer "" with hidden answer with icon caution buttons {"Cancel", "OK"} default button "OK"
        return text returned of answer
        APPLESCRIPT
        """.write(to: askpass, atomically: true, encoding: .utf8)
        // A script that calls plain `sudo` gets the dialog too.
        let sudo = bin.appendingPathComponent("sudo")
        try "#!/bin/bash\nexec /usr/bin/sudo -A \"$@\"\n".write(to: sudo, atomically: true, encoding: .utf8)
        for executable in [askpass, sudo] {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        await Privileged.bringAppForward()
        let environment = [
            "SUDO_ASKPASS": askpass.path,
            "NONINTERACTIVE": "1",
            "PATH": "\(bin.path):\(Shell.environment["PATH"] ?? "/usr/bin:/bin")",
        ]
        let status = await Shell.stream("/bin/bash", [file.path], environment: environment, onLine: onLine)
        guard status == 0 else { throw ShellError("\(what) failed (exit \(status)).") }
    }
}
