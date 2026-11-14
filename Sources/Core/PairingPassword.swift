import Foundation
import CommonCrypto
import Security

/// A short, typeable pairing password, stretched into the 256-bit TLS pre-shared key.
///
/// Security model (be honest about it): TLS-PSK is not a password-authenticated key exchange. Anyone who records
/// one handshake on the LAN, or who connects once to the Mac, can test password guesses offline against it. The
/// only defences are the password's own entropy and the cost of each guess, which PBKDF2-HMAC-SHA256 with
/// `iterations` rounds sets at roughly 0.14 s on an M4 Max core (about 1 million SHA-256 HMACs per guess).
///
/// Salt: a fixed, SkyDesk-specific value. A per-Mac random salt would also stop precomputed tables, but it must
/// reach the iPad before the handshake, and Apple's TLS-PSK implementation fails every handshake once the
/// server sets an identity hint (tested 2026-11-12 with matching keys, five variants), so there is no channel
/// for it on a manual IP connection. Precomputation against this salt only pays off across many SkyDesk users.
public enum PairingPassword {
    /// PSK identity of the password scheme. Version 1 was the raw 64-hex key; mixed versions cannot handshake.
    public static let pskIdentity = "SkyDesk-v2"
    public static let iterations: UInt32 = 1_000_000
    public static let minimumLength = 6
    private static let salt = Data("SkyDesk pairing password v2 · com.skylar.skydesk".utf8)
    /// No 0/o, 1/l/i: easy to read off the Mac and type on the iPad.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let mismatchMessage = "Wrong password. Check the password shown in SkyDesk on your Mac. (If it is right, update SkyDesk on both devices.)"

    /// Spaces and dashes are ignored, so "k7mq-3xvp" and "k7mq3xvp" are the same password. Case matters.
    public static func normalized(_ password: String) -> String {
        String(password.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "-"
        }.map(Character.init))
    }
    public static func validate(_ password: String) throws {
        guard normalized(password).count >= minimumLength else {
            throw DeskError.invalid("Use at least \(minimumLength) letters or numbers (dashes and spaces don't count).")
        }
        guard normalized(password).utf8.count <= 128 else { throw DeskError.invalid("That password is too long.") }
    }
    /// Deliberately slow; call off the main thread.
    public static func deriveKey(_ password: String, iterations: UInt32 = iterations) throws -> PairingKey {
        try validate(password)
        let secret = Array(normalized(password).utf8)
        let saltBytes = Array(salt)
        var output = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { Int8(bitPattern: $0) }, secret.count,
                                          saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          iterations, &output, output.count)
        guard status == kCCSuccess else { throw DeskError.system("Derive pairing key", Int32(status)) }
        return PairingKey(data: Data(output))
    }
    /// Eight random characters from a 31-symbol alphabet (≈ 39.6 bits), shown as "xxxx-xxxx".
    public static func generate() throws -> String {
        var characters: [Character] = []
        while characters.count < 8 {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { throw DeskError.system("Generate password", status) }
            // Rejection sampling keeps every symbol equally likely.
            if Int(byte) < 248 { characters.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }
}
