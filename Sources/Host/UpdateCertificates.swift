import Foundation
import Security

/// The per-Mac certificate authority for wireless updates, and the short-lived server certificate it signs.
///
/// Files live in ~/Library/Application Support/SkyDesk/UpdateCA (folder 0700, keys 0600). The CA is restricted by
/// critical name constraints to private IPv4 ranges and `.local`, so even a stolen CA key cannot impersonate a
/// public website to the iPad (Apple's trust evaluation rejects such certificates; see Verification notes).
enum UpdateCertificates {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SkyDesk", isDirectory: true)
    static let folder = support.appendingPathComponent("UpdateCA", isDirectory: true)
    private static let openssl = "/usr/bin/openssl"
    private static let p12Password = "skydesk-update"

    /// Creates the CA on first use. Returns its certificate in DER form.
    static func caDER() throws -> Data {
        try ensureCA()
        return try der(fromPEM: folder.appendingPathComponent("ca.pem"))
    }
    /// A server identity valid for `addresses` (IPv4 and .local names), re-issued when they change or near expiry.
    static func identity(for addresses: [String]) throws -> SecIdentity {
        try ensureCA()
        let names = Array(Set(addresses.filter(Self.allowed))).sorted()
        guard !names.isEmpty else { throw DeskError.invalid("This Mac has no private network address for updates.") }
        let stamp = folder.appendingPathComponent("leaf.names")
        let p12 = folder.appendingPathComponent("leaf.p12")
        let current = (try? String(contentsOf: stamp, encoding: .utf8)) == names.joined(separator: ",")
        let fresh = ((try? p12.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            > Date().addingTimeInterval(-300 * 86_400)
        if !(current && fresh) {
            let san = names.map { $0.hasSuffix(".local") ? "DNS:\($0)" : "IP:\($0)" }.joined(separator: ",")
            let config = """
            [req]
            distinguished_name=dn
            prompt=no
            [dn]
            CN=SkyDesk update server
            [ext]
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature
            extendedKeyUsage=serverAuth
            subjectAltName=\(san)
            """
            try write(config, "leaf.cnf")
            try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"])
            try run(["req", "-new", "-key", "leaf.key", "-config", "leaf.cnf", "-out", "leaf.csr"])
            try run(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                     "-days", "365", "-sha256", "-extfile", "leaf.cnf", "-extensions", "ext", "-out", "leaf.pem"])
            try run(["pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-passout", "pass:\(p12Password)", "-out", "leaf.p12"])
            try protect("leaf.key"); try protect("leaf.p12")
            try names.joined(separator: ",").write(to: stamp, atomically: true, encoding: .utf8)
        }
        return try UpdateIdentity.load(p12: Data(contentsOf: p12), password: p12Password)
    }
    static func allowed(_ name: String) -> Bool {
        if name.hasSuffix(".local") { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }
    private static func ensureCA() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("ca.pem").path) else { return }
        let config = """
        [req]
        distinguished_name=dn
        x509_extensions=v3_ca
        prompt=no
        [dn]
        CN=SkyDesk Update CA (\(Host.current().localizedName ?? "Mac"))
        [v3_ca]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        nameConstraints=critical,permitted;IP:10.0.0.0/255.0.0.0,permitted;IP:172.16.0.0/255.240.0.0,permitted;IP:192.168.0.0/255.255.0.0,permitted;IP:169.254.0.0/255.255.0.0,permitted;DNS:.local
        """
        try write(config, "ca.cnf")
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"])
        try protect("ca.key")
        try run(["req", "-new", "-x509", "-key", "ca.key", "-days", "3650", "-sha256", "-config", "ca.cnf", "-out", "ca.pem"])
    }
    private static func der(fromPEM url: URL) throws -> Data {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { throw DeskError.invalid("Unreadable update certificate.") }
        return data
    }
    private static func write(_ text: String, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private static func protect(_ name: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(name).path)
    }
    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DeskError.invalid("Update certificate: openssl \(arguments.first ?? "") failed. \(message.prefix(160))")
        }
    }
}

/// Replaces the running host app with a staged build: a detached script waits for this process to exit,
/// checks the new app's signature and that its designated requirement matches (so Keychain and privacy grants
/// keep working), swaps it in, unregisters the staged copy from Launch Services and relaunches. On any failure
/// it puts the old app back and relaunches that.
enum SelfUpdater {
    /// Signature + designated-requirement check, done ahead of time (when the iPad asks for the update) so the
    /// swap itself is instant. Same requirement = Keychain items and privacy permissions keep working.
    static func verify(_ staged: URL) -> Bool {
        func run(_ args: [String]) -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, "") }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit(); return (p.terminationStatus, out)
        }
        func requirement(_ url: URL) -> String? {
            run(["-d", "-r-", url.path]).1.components(separatedBy: "\n").first { $0.hasPrefix("designated") }
        }
        guard run(["--verify", "--deep", "--strict", staged.path]).0 == 0,
              let new = requirement(staged), new == requirement(Bundle.main.bundleURL) else { return false }
        return true
    }
    /// A detached script waits (polling every 0.1 s) for this process to exit, then swaps the staged app in with two
    /// renames on the same volume, keeps the old app as Updates/previous-host.app, and relaunches.
    /// Call only after `verify` passed.
    static func replace(with staged: URL) throws {
        let current = Bundle.main.bundleURL
        let backup = UpdateCertificates.support.appendingPathComponent("Updates/previous-host.app")
        let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SkyDesk/update.log")
        let script = """
        #!/bin/zsh
        APP=\(quote(current.path)); NEW=\(quote(staged.path)); BACKUP=\(quote(backup.path)); PID=\(ProcessInfo.processInfo.processIdentifier)
        exec >> \(quote(log.path)) 2>&1
        echo "$(date '+%F %T') update: waiting for host $PID to quit"
        for i in {1..300}; do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
        if pgrep -f SkyDeskRestore >/dev/null; then echo "display restore helper running; not replacing"; open "$APP"; exit 1; fi
        rm -rf "$BACKUP"
        if mv "$APP" "$BACKUP" && { mv "$NEW" "$APP" || ditto "$NEW" "$APP"; }; then
          echo "replaced with build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
        else rm -rf "$APP"; mv "$BACKUP" "$APP"; echo "swap failed; restored the previous app"; fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$NEW" 2>/dev/null
        open "$APP"
        echo "$(date '+%F %T') update: relaunched"
        """
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("skydesk-self-update.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "nohup /bin/zsh \(quote(file.path)) >/dev/null 2>&1 &"]
        try process.run(); process.waitUntilExit()
    }
    private static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
