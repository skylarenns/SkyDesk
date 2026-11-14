import Foundation
import Network
import Security

/// Cable-free updates: the Mac serves a staged iPad build over HTTPS and iPadOS installs it with
/// `itms-services` (over-the-air install). The HTTPS certificate comes from a per-Mac CA that the user installs
/// and trusts on the iPad once. That CA carries critical X.509 name constraints (private IPv4 ranges and `.local`
/// only); Apple's trust evaluation rejects anything else it signs (tested: apple.com and a public IP rejected).
public enum UpdatePort { public static let https: UInt16 = 48773 }

/// What a published update contains. Lives beside the files in the Mac's update folder.
public struct UpdateInfo: Codable, Equatable {
    public let build: Int
    public init(build: Int) { self.build = build }
    public static let folderName = "ready"
    public static let ipaName = "SkyDesk.ipa"
    public static let hostAppName = "SkyDesk Host.app"
    public static func load(from folder: URL) -> UpdateInfo? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")) else { return nil }
        return try? JSONDecoder().decode(UpdateInfo.self, from: data)
    }
}

public enum UpdateManifest {
    /// The plist iPadOS fetches before installing.
    public static func plist(ipaURL: URL, bundleID: String, version: String, title: String) throws -> Data {
        let manifest: [String: Any] = ["items": [[
            "assets": [["kind": "software-package", "url": ipaURL.absoluteString]],
            "metadata": ["bundle-identifier": bundleID, "bundle-version": version, "kind": "software", "title": title]
        ]]]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }
    public static func installURL(manifest: URL) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: ":/?&=")
        guard let encoded = manifest.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "itms-services://?action=download-manifest&url=" + encoded)
    }
    /// An unsigned configuration profile that installs `caDER` as a root certificate (the user still has to
    /// switch on full trust in Settings › General › About › Certificate Trust Settings).
    public static func profile(caDER: Data, macName: String) throws -> Data {
        let id = "com.skylar.skydesk.update-ca"
        let payload: [String: Any] = [
            "PayloadContent": [[
                "PayloadCertificateFileName": "SkyDesk Update CA.cer", "PayloadContent": caDER,
                "PayloadDescription": "Lets SkyDesk on \(macName) install SkyDesk updates over Wi-Fi.",
                "PayloadDisplayName": "SkyDesk Update CA", "PayloadIdentifier": id + ".cert",
                "PayloadType": "com.apple.security.root", "PayloadUUID": UUID().uuidString, "PayloadVersion": 1
            ]],
            "PayloadDescription": "Lets SkyDesk on \(macName) install SkyDesk updates on this iPad over Wi-Fi. The certificate only works for private network addresses (10.x, 172.16–31.x, 192.168.x, 169.254.x) and .local names, never for websites. Remove it any time in Settings › General › VPN & Device Management.",
            "PayloadDisplayName": "SkyDesk wireless updates", "PayloadIdentifier": id,
            "PayloadOrganization": "SkyDesk", "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration", "PayloadUUID": UUID().uuidString, "PayloadVersion": 1
        ]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }
}

/// Just enough HTTP/1.1 for the iPadOS installer: GET (and HEAD), one request per connection.
public enum MiniHTTP {
    /// Returns (method, path) once the request head is complete; nil while incomplete. Throws on garbage.
    public static func requestLine(_ data: Data) throws -> (method: String, path: String)? {
        try request(data).map { ($0.method, $0.path) }
    }
    /// Method, path and headers (lower-cased names) once the head is complete.
    public static func request(_ data: Data) throws -> (method: String, path: String, headers: [String: String])? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw DeskError.invalid("Request too large.") }
            return nil
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else { throw DeskError.invalid("Bad request.") }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { throw DeskError.invalid("Bad request.") }
        var headers: [String: String] = [:]
        for field in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = field.firstIndex(of: ":") else { continue }
            headers[field[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(parts[0]), String(parts[1]), headers)
    }
    /// A single "bytes=start-[end]" range within `size`, as a half-open range. nil = whole file (no or unusable header).
    public static func byteRange(_ header: String?, size: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty, let suffix = Int(spec[1]), suffix > 0 { return max(0, size - suffix)..<size }
        guard let start = Int(spec[0]), start < size else { return nil }
        let end = spec[1].isEmpty ? size - 1 : min(size - 1, Int(spec[1]) ?? size - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
    public static func head(status: Int, reason: String, type: String, length: Int, extra: String = "") -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\n\(extra)Cache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    }
}

/// Serves one staged update over HTTPS: `/<token>/manifest.plist`, `/<token>/SkyDesk.ipa`, `/<token>/ping`.
/// Every other path is 404, so only someone told the random token (over the paired SkyDesk link) gets anything.
public final class UpdateServer {
    public var onIPAServed: (() -> Void)?
    public var onLog: ((String) -> Void)?
    public let token: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "skydesk.update-server", qos: .utility)
    private let manifest: Data
    private let ipa: URL
    public let host: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var stopped = false

    public init(identity: SecIdentity, port: UInt16 = UpdatePort.https, manifest: (URL) throws -> Data,
                ipa: URL, baseHost: String) throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DeskError.invalid("No randomness.") }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw DeskError.invalid("Bad update certificate.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.ipa = ipa; self.host = baseHost
        self.manifest = try manifest(Self.url(host: baseHost, port: port, token: token, file: UpdateInfo.ipaName))
    }
    public static func url(host: String, port: UInt16, token: String, file: String) -> URL {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(bracketed):\(port)/\(token)/\(file)")!
    }
    public func start(ready: @escaping (Error?) -> Void) {
        var reported = false
        listener.stateUpdateHandler = { state in
            guard !reported else { return }
            switch state {
            case .ready: reported = true; ready(nil)
            case .failed(let error): reported = true; ready(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    public func stop() {
        stopped = true
        queue.async { [self] in
            listener.cancel()
            connections.values.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.connections.removeValue(forKey: ObjectIdentifier(connection))
            default: break
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 300) { connection.cancel() }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try MiniHTTP.request(buffer) { self.respond(connection, request.method, request.path, range: request.headers["range"]) }
                else if complete || error != nil { connection.cancel() }
                else { self.read(connection, buffer: buffer) }
            } catch { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, _ method: String, _ path: String, range: String?) {
        let headOnly = method == "HEAD"
        guard method == "GET" || headOnly else { return finish(connection, MiniHTTP.head(status: 405, reason: "Method Not Allowed", type: "text/plain", length: 0)) }
        switch path {
        case "/\(token)/ping":
            let body = Data("ok".utf8)
            finish(connection, MiniHTTP.head(status: 200, reason: "OK", type: "text/plain", length: body.count) + (headOnly ? Data() : body))
        case "/\(token)/manifest.plist":
            onLog?("update: manifest requested")
            finish(connection, MiniHTTP.head(status: 200, reason: "OK", type: "text/xml", length: manifest.count) + (headOnly ? Data() : manifest))
        case "/\(token)/\(UpdateInfo.ipaName)":
            // Size read fresh each time: URL resource values are cached, and a cached size once served a newer
            // file cut to the old length (2026-11-13 09:01).
            guard let handle = try? FileHandle(forReadingFrom: ipa),
                  let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.intValue else {
                return finish(connection, MiniHTTP.head(status: 404, reason: "Not Found", type: "text/plain", length: 0))
            }
            // iPadOS resumes interrupted downloads with a Range request; answer it with exactly those bytes.
            let part = MiniHTTP.byteRange(range, size: size)
            let span = part ?? 0..<size
            onLog?("update: iPad app download " + (part.map { "resumed at byte \($0.lowerBound)" } ?? "started") + " (\(span.count) of \(size) bytes)")
            let head = part == nil
                ? MiniHTTP.head(status: 200, reason: "OK", type: "application/octet-stream", length: size)
                : MiniHTTP.head(status: 206, reason: "Partial Content", type: "application/octet-stream", length: span.count,
                                extra: "Content-Range: bytes \(span.lowerBound)-\(span.upperBound - 1)/\(size)\r\n")
            do { try handle.seek(toOffset: UInt64(span.lowerBound)) } catch { try? handle.close(); connection.cancel(); return }
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard error == nil, !headOnly else { try? handle.close(); if headOnly { self?.closeGracefully(connection) }; return }
                self?.stream(handle, to: connection, remaining: span.count, finishesFile: span.upperBound == size)
            })
        default:
            finish(connection, MiniHTTP.head(status: 404, reason: "Not Found", type: "text/plain", length: 0))
        }
    }
    private func stream(_ handle: FileHandle, to connection: NWConnection, remaining: Int, finishesFile: Bool) {
        guard remaining > 0 else {
            try? handle.close()
            onLog?("update: iPad app bytes handed to the network" + (finishesFile ? " (end of file)" : ""))
            if finishesFile { onIPAServed?() }
            closeGracefully(connection)
            return
        }
        guard let chunk = try? handle.read(upToCount: min(remaining, 1_048_576)), !chunk.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                // The installer may close as soon as it has every byte; that still counts as delivered.
                if finishesFile, remaining == chunk.count { self?.onLog?("update: iPad app delivered (client closed first)"); self?.onIPAServed?() }
                try? handle.close(); connection.cancel(); return
            }
            self?.stream(handle, to: connection, remaining: remaining - chunk.count, finishesFile: finishesFile)
        })
    }
    private func finish(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.closeGracefully(connection) })
    }
    /// Sends FIN and lets the client close. Cancelling right after the last send discarded bytes still queued in
    /// the socket (iPadOS logged "network connection lost" at 508 of 647 KB, 2026-11-12 23:34).
    private func closeGracefully(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        drain(connection)
        queue.asyncAfter(deadline: .now() + 60) { connection.cancel() }
    }
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] _, _, complete, error in
            if complete || error != nil { connection.cancel() } else { self?.drain(connection) }
        }
    }
}

#if os(macOS)
public enum UpdateIdentity {
    /// Loads a PKCS#12 identity into memory only (never into the Keychain, so no Keychain prompts or leftovers).
    public static func load(p12: Data, password: String) throws -> SecIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        else { throw DeskError.invalid("Wireless updates need macOS 15 or later.") }
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw DeskError.system("Load update certificate", status) }
        return identity as! SecIdentity
    }
}
#endif
