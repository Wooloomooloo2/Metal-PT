import Foundation
import CryptoKit

/// Signs with a P-256 key. `sign` returns the raw 64-byte r‖s ECDSA-SHA256 signature (what WebCrypto verifies);
/// `publicKeyX963` is the 65-byte uncompressed point.
public protocol RunSigner: Sendable {
    var publicKeyX963: Data { get }
    func sign(_ message: Data) throws -> Data
}

/// A software P-256 signer, for tests, fixtures and Macs without a Secure Enclave.
public struct SoftwareSigner: RunSigner {
    private let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }
    public init(rawKey: Data) throws { self.key = try P256.Signing.PrivateKey(rawRepresentation: rawKey) }

    public var publicKeyX963: Data { key.publicKey.x963Representation }
    public var rawKey: Data { key.rawRepresentation }

    public func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

/// The exact messages the website verifies (spec §4.B). Hash arguments are lowercase hex SHA-256.
public enum SiteSigning {
    public static func publishMessage(bundle: String, run: String, samples: String, summary: String,
                                      timestamp: String) -> Data {
        Data(["metal-pt-run", bundle, run, samples, summary, timestamp].joined(separator: "\n").utf8)
    }

    public static func patchMessage(id: String, bodySHA256: String, timestamp: String) -> Data {
        Data(["metal-pt-patch", id, bodySHA256, timestamp].joined(separator: "\n").utf8)
    }

    public static func deleteMessage(id: String, timestamp: String) -> Data {
        Data(["metal-pt-delete", id, timestamp].joined(separator: "\n").utf8)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// First 16 hex characters of SHA-256 over the public key's X9.63 bytes.
    public static func keyID(publicKeyX963: Data) -> String {
        String(SHA256.hash(data: publicKeyX963).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// ISO-8601 UTC, whole seconds.
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
