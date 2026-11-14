import XCTest
import Security
@testable import SkyDeskCore

final class UpdateTests: XCTestCase {
    func testManifestAndInstallURL() throws {
        let ipa = URL(string: "https://10.0.0.5:48773/abc/SkyDesk.ipa")!
        let data = try UpdateManifest.plist(ipaURL: ipa, bundleID: "com.skylar.skydesk.pad", version: "18", title: "SkyDesk")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let item = try XCTUnwrap((plist["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(((item["assets"] as? [[String: String]])?.first)?["url"], ipa.absoluteString)
        XCTAssertEqual((item["metadata"] as? [String: String])?["bundle-identifier"], "com.skylar.skydesk.pad")
        let install = try XCTUnwrap(UpdateManifest.installURL(manifest: URL(string: "https://10.0.0.5:48773/abc/manifest.plist")!))
        XCTAssertEqual(install.absoluteString, "itms-services://?action=download-manifest&url=https%3A%2F%2F10.0.0.5%3A48773%2Fabc%2Fmanifest.plist")
    }
    func testProfileInstallsOneRootCertificate() throws {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        let data = try UpdateManifest.profile(caDER: der, macName: "Studio")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["PayloadType"] as? String, "Configuration")
        let content = try XCTUnwrap((plist["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(content["PayloadContent"] as? Data, der)
    }
    func testRequestParsing() throws {
        XCTAssertNil(try MiniHTTP.requestLine(Data("GET /x HTTP/1.1\r\nHost: a\r\n".utf8)), "incomplete head")
        let request = try XCTUnwrap(try MiniHTTP.requestLine(Data("GET /tok/manifest.plist HTTP/1.1\r\nHost: a\r\n\r\n".utf8)))
        XCTAssertEqual(request.method, "GET"); XCTAssertEqual(request.path, "/tok/manifest.plist")
        XCTAssertThrowsError(try MiniHTTP.requestLine(Data("garbage\r\n\r\n".utf8)))
        XCTAssertThrowsError(try MiniHTTP.requestLine(Data(repeating: 65, count: 20_000)))
        XCTAssertEqual(UpdateInfo(build: 18), try JSONDecoder().decode(UpdateInfo.self, from: Data(#"{"build":18}"#.utf8)))
    }

    /// Real TLS: a name-constrained CA and server certificate from /usr/bin/openssl, the update server, and
    /// URLSession trusting only that CA (as the iPad will after the one-time setup).
    func testServerDeliversManifestAndAppOverTrustedHTTPS() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skydesk-upd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func ssl(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args
            p.currentDirectoryURL = dir; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
        }
        try """
        [req]
        distinguished_name=dn
        x509_extensions=v3_ca
        prompt=no
        [dn]
        CN=Test CA
        [v3_ca]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        nameConstraints=critical,permitted;IP:127.0.0.0/255.0.0.0,permitted;IP:10.0.0.0/255.0.0.0
        """.write(to: dir.appendingPathComponent("ca.cnf"), atomically: true, encoding: .utf8)
        try """
        [req]
        distinguished_name=dn
        prompt=no
        [dn]
        CN=server
        [ext]
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=serverAuth
        subjectAltName=IP:127.0.0.1
        """.write(to: dir.appendingPathComponent("leaf.cnf"), atomically: true, encoding: .utf8)
        try ssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"])
        try ssl(["req", "-new", "-x509", "-key", "ca.key", "-days", "30", "-sha256", "-config", "ca.cnf", "-out", "ca.pem"])
        try ssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"])
        try ssl(["req", "-new", "-key", "leaf.key", "-config", "leaf.cnf", "-out", "leaf.csr"])
        try ssl(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "30",
                 "-sha256", "-extfile", "leaf.cnf", "-extensions", "ext", "-out", "leaf.pem"])
        try ssl(["pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-passout", "pass:t", "-out", "leaf.p12"])
        let identity = try UpdateIdentity.load(p12: Data(contentsOf: dir.appendingPathComponent("leaf.p12")), password: "t")
        let pem = try String(contentsOf: dir.appendingPathComponent("ca.pem"), encoding: .utf8)
        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(base64Encoded: pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined())! as CFData))

        let ipa = dir.appendingPathComponent("SkyDesk.ipa")
        let payload = Data((0..<(2_500_000)).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: ipa)
        let server = try UpdateServer(identity: identity, port: 48_799, manifest: { url in
            try UpdateManifest.plist(ipaURL: url, bundleID: "b", version: "1", title: "t")
        }, ipa: ipa, baseHost: "127.0.0.1")
        let served = expectation(description: "ipa served"); served.assertForOverFulfill = false; server.onIPAServed = { served.fulfill() }
        let ready = expectation(description: "ready"); server.start { XCTAssertNil($0); ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: AnchorTrust(anchor: ca), delegateQueue: nil)
        func get(_ path: String, range: String? = nil) throws -> (Int, Data) {
            let done = expectation(description: path); var result: (Int, Data) = (0, Data())
            var request = URLRequest(url: URL(string: "https://127.0.0.1:48799" + path)!)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            session.dataTask(with: request) { data, response, error in
                XCTAssertNil(error, path); result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); done.fulfill()
            }.resume()
            wait(for: [done], timeout: 10); return result
        }
        let manifest = try get("/\(server.token)/manifest.plist")
        XCTAssertEqual(manifest.0, 200)
        XCTAssertTrue(String(decoding: manifest.1, as: UTF8.self).contains("https://127.0.0.1:48799/\(server.token)/SkyDesk.ipa"))
        XCTAssertEqual(try get("/wrongtoken/SkyDesk.ipa").0, 404)
        XCTAssertEqual(try get("/\(server.token)/ping").0, 200)
        let resumed = try get("/\(server.token)/SkyDesk.ipa", range: "bytes=1000000-")
        XCTAssertEqual(resumed.0, 206); XCTAssertEqual(resumed.1, payload.subdata(in: 1_000_000..<payload.count))
        let app = try get("/\(server.token)/SkyDesk.ipa")
        XCTAssertEqual(app.0, 200); XCTAssertEqual(app.1, payload)
        wait(for: [served], timeout: 5)
    }
}

private final class AnchorTrust: NSObject, URLSessionDelegate {
    let anchor: SecCertificate
    init(anchor: SecCertificate) { self.anchor = anchor }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        completionHandler(SecTrustEvaluateWithError(trust, nil) ? .useCredential : .cancelAuthenticationChallenge,
                          SecTrustEvaluateWithError(trust, nil) ? URLCredential(trust: trust) : nil)
    }
}

final class UpdateRangeTests: XCTestCase {
    func testRangeRequestsAreUnderstood() throws {
        XCTAssertEqual(MiniHTTP.byteRange("bytes=507904-", size: 647_102), 507_904..<647_102)
        XCTAssertEqual(MiniHTTP.byteRange("bytes=0-99", size: 1_000), 0..<100)
        XCTAssertEqual(MiniHTTP.byteRange("bytes=-100", size: 1_000), 900..<1_000)
        XCTAssertEqual(MiniHTTP.byteRange("bytes=10-5000", size: 1_000), 10..<1_000)
        XCTAssertNil(MiniHTTP.byteRange(nil, size: 1_000))
        XCTAssertNil(MiniHTTP.byteRange("bytes=2000-", size: 1_000))
        XCTAssertNil(MiniHTTP.byteRange("bytes=0-1,5-9", size: 1_000))
        let request = try XCTUnwrap(try MiniHTTP.request(Data("GET /t/SkyDesk.ipa HTTP/1.1\r\nHost: x\r\nRange: bytes=507904-\r\n\r\n".utf8)))
        XCTAssertEqual(request.headers["range"], "bytes=507904-")
    }
}
