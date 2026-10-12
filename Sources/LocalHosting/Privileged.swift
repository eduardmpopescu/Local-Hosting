import AppKit
import Foundation

/// Editing /etc/hosts needs root. A one-time setup installs a small root-owned helper script
/// plus a sudoers rule that lets this user run only that script without a password.
enum Privileged {
    static let helperPath = "/usr/local/libexec/localhosting-helper"
    static let sudoersPath = "/etc/sudoers.d/localhosting"
    static let helperVersion = "1"

    static let beginMarker = "# >>> Local Hosting (managed automatically, do not edit) >>>"
    static let endMarker = "# <<< Local Hosting <<<"

    /// The helper validates every hostname itself, so the sudoers rule can't be abused
    /// to write arbitrary content into /etc/hosts.
    static var helperScript: String {
        """
        #!/bin/bash
        # Local Hosting privileged helper (version \(helperVersion)).
        # Maintains a marked block in /etc/hosts pointing hostnames at this Mac.
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        HOSTS=/private/etc/hosts
        BEGIN='\(beginMarker)'
        END='\(endMarker)'
        NAME_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'

        flush_dns() {
            dscacheutil -flushcache
            killall -HUP mDNSResponder 2>/dev/null || true
        }

        case "$1" in
            version)
                echo \(helperVersion)
                ;;
            set-hosts)
                shift
                for name in "$@"; do
                    if ! [[ "$name" =~ $NAME_RE ]] || [ ${#name} -gt 253 ]; then
                        echo "Invalid hostname: $name" >&2
                        exit 2
                    fi
                done
                tmp=$(mktemp /private/etc/hosts.localhosting.XXXXXX) || exit 1
                awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$HOSTS" > "$tmp"
                if [ $# -gt 0 ]; then
                    {
                        echo "$BEGIN"
                        for name in "$@"; do
                            printf '127.0.0.1\\t%s\\n::1\\t%s\\n' "$name" "$name"
                        done
                        echo "$END"
                    } >> "$tmp"
                fi
                chown root:wheel "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$HOSTS"
                flush_dns
                ;;
            flush-dns)
                flush_dns
                ;;
            *)
                echo "usage: $0 version | set-hosts [hostname...] | flush-dns" >&2
                exit 1
                ;;
        esac
        """
    }

    static func installedVersion() async -> String? {
        guard FileManager.default.fileExists(atPath: helperPath) else { return nil }
        let result = await Shell.run("/usr/bin/sudo", ["-n", helperPath, "version"])
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func isInstalled() async -> Bool {
        await installedVersion() == helperVersion
    }

    /// Shows the macOS administrator prompt once and installs the helper and sudoers rule.
    static func install() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localhosting-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let helper = tmp.appendingPathComponent("helper")
        let sudoers = tmp.appendingPathComponent("sudoers")
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try "\(NSUserName()) ALL=(root) NOPASSWD: \(helperPath)\n".write(to: sudoers, atomically: true, encoding: .utf8)

        let script = [
            "/usr/bin/install -d -o root -g wheel -m 755 /usr/local/libexec",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(helper.path)) \(helperPath)",
            "/usr/sbin/visudo -cf \(shellQuote(sudoers.path))",
            "/usr/bin/install -o root -g wheel -m 440 \(shellQuote(sudoers.path)) \(sudoersPath)",
        ].joined(separator: " && ")
        try await runAsAdmin(script, prompt: "Local Hosting needs to install a small helper so it can point your addresses at This Mac. You'll only be asked once.")

        guard await isInstalled() else {
            throw ShellError("The helper was installed but can't be run without a password. Check \(sudoersPath).")
        }
    }

    /// Replaces the managed block in /etc/hosts with these hostnames (an empty list removes it).
    static func setHosts(_ hostnames: [String]) async throws {
        // /etc/hosts is shared with the real app; a test run must never change it.
        guard !Paths.isTestRun else { return }
        try await Shell.check("/usr/bin/sudo", ["-n", helperPath, "set-hosts"] + hostnames, what: "Updating /etc/hosts")
    }

    static var hostsHasManagedBlock: Bool {
        ((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "").contains(beginMarker)
    }

    /// Makes this the frontmost app. macOS shows its password / Touch ID prompt for whichever app asks,
    /// and the prompt only takes the keyboard when that app is in front.
    static func bringAppForward() async {
        await MainActor.run { NSApp.activate() }
    }

    private static func runAsAdmin(_ command: String, prompt: String) async throws {
        func appleScriptString(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        await bringAppForward()
        // Run inside this app (not through the osascript command), so the prompt belongs to Local Hosting
        // and opens in front with the keyboard focus. A background thread keeps the window responsive.
        let failure: (number: Int, message: String)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var info: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&info)
                guard let info else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (
                    info[NSAppleScript.errorNumber] as? Int ?? 0,
                    info[NSAppleScript.errorMessage] as? String ?? "Unknown error."
                ))
            }
        }
        if let failure {
            if failure.number == -128 { throw ShellError("Cancelled.") }
            throw ShellError("Administrator step failed.\n\(failure.message)")
        }
    }
}
