import Foundation

/// A private certificate authority, trusted in the login keychain, that signs a certificate
/// per server. This is what lets https://example.com load the local site without warnings,
/// even when the real domain uses HSTS.
enum Certificates {
    struct Pair {
        let cert: URL
        let key: URL
    }

    static var caExists: Bool {
        FileManager.default.fileExists(atPath: Paths.caCert.path) && FileManager.default.fileExists(atPath: Paths.caKey.path)
    }

    static func isCATrusted() async -> Bool {
        guard caExists else { return false }
        return await Shell.run("/usr/bin/security", ["verify-cert", "-c", Paths.caCert.path, "-p", "ssl", "-q"]).ok
    }

    static func createCA() async throws {
        Paths.ensureDirectories()
        guard !caExists else { return }
        let user = NSUserName()
        try await Shell.check(Paths.openssl, [
            "req", "-x509", "-new", "-nodes", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
            "-keyout", Paths.caKey.path, "-out", Paths.caCert.path,
            "-subj", "/O=Local Hosting/CN=Local Hosting CA (\(user))",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
        ], what: "Creating the certificate authority")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.caKey.path)
    }

    /// Adds the CA to the login keychain as trusted for SSL. macOS shows its own password / Touch ID prompt.
    static func trustCA() async throws {
        try await createCA()
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        // The macOS prompt takes the keyboard only while this app is in front.
        await Privileged.bringAppForward()
        try await Shell.check("/usr/bin/security", [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, Paths.caCert.path,
        ], what: "Trusting the certificate authority")
    }

    /// A certificate covering all of the server's hostnames.
    static func ensure(for server: Server) async throws -> Pair {
        try await ensure(name: server.id.uuidString, dnsNames: server.hostnames)
    }

    /// The certificate for the catch-all page that answers unknown hostnames over HTTPS.
    static func ensureFallback() async throws -> Pair {
        try await ensure(name: "localhost", dnsNames: ["localhost"], ipAddresses: ["127.0.0.1", "::1"])
    }

    /// (Re)issues the certificate when it's missing, its names changed, it expires within 30 days,
    /// or it was signed by an earlier certificate authority (browsers would reject it).
    private static func ensure(name: String, dnsNames: [String], ipAddresses: [String] = []) async throws -> Pair {
        try await createCA()
        let base = Paths.serverCerts.appendingPathComponent(name)
        let pair = Pair(cert: base.appendingPathExtension("crt"), key: base.appendingPathExtension("key"))
        let namesFile = base.appendingPathExtension("names")
        let sans = (dnsNames.map { "DNS:\($0)" } + ipAddresses.map { "IP:\($0)" }).joined(separator: ",")

        let fm = FileManager.default
        if fm.fileExists(atPath: pair.cert.path), fm.fileExists(atPath: pair.key.path),
           (try? String(contentsOf: namesFile, encoding: .utf8)) == sans,
           await Shell.run(Paths.openssl, ["x509", "-checkend", "2592000", "-noout", "-in", pair.cert.path]).ok,
           await Shell.run(Paths.openssl, ["verify", "-CAfile", Paths.caCert.path, pair.cert.path]).ok {
            return pair
        }

        let csr = base.appendingPathExtension("csr")
        let ext = base.appendingPathExtension("ext")
        defer {
            try? fm.removeItem(at: csr)
            try? fm.removeItem(at: ext)
        }
        try """
        basicConstraints=CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(sans)
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid,issuer
        """.write(to: ext, atomically: true, encoding: .utf8)

        try await Shell.check(Paths.openssl, [
            "req", "-new", "-nodes", "-newkey", "rsa:2048", "-sha256",
            "-keyout", pair.key.path, "-out", csr.path, "-subj", "/CN=\(dnsNames[0])",
        ], what: "Creating a key for \(dnsNames[0])")

        let serial = "0x" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        // 397 days is the longest validity Safari accepts for TLS certificates.
        try await Shell.check(Paths.openssl, [
            "x509", "-req", "-in", csr.path, "-CA", Paths.caCert.path, "-CAkey", Paths.caKey.path,
            "-set_serial", serial, "-days", "397", "-sha256", "-extfile", ext.path, "-out", pair.cert.path,
        ], what: "Signing the certificate for \(dnsNames[0])")

        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pair.key.path)
        try sans.write(to: namesFile, atomically: true, encoding: .utf8)
        return pair
    }

    static func remove(for server: Server) {
        let base = Paths.serverCerts.appendingPathComponent(server.id.uuidString)
        for ext in ["crt", "key", "names"] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
        }
    }
}
