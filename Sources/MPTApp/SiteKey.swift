import Foundation
import CryptoKit
import MPTCore

/// A created or restored key: its public point, a signer, and the bytes to store.
public struct SiteKeyHandle: Sendable {
    public let publicKeyX963: Data
    public let stored: Data
    public let sign: @Sendable (Data) throws -> Data
}

/// Where keys come from. `kind` is the first byte of the key file, so a file written by one backend is never
/// handed to another.
public protocol SiteKeyBackend: Sendable {
    var kind: UInt8 { get }
    func create() throws -> SiteKeyHandle
    func restore(_ stored: Data) throws -> SiteKeyHandle
}

public struct SoftwareKeyBackend: SiteKeyBackend {
    public init() {}
    public var kind: UInt8 { 2 }
    public func create() throws -> SiteKeyHandle { Self.handle(P256.Signing.PrivateKey()) }
    public func restore(_ stored: Data) throws -> SiteKeyHandle {
        Self.handle(try P256.Signing.PrivateKey(rawRepresentation: stored))
    }
    private static func handle(_ k: P256.Signing.PrivateKey) -> SiteKeyHandle {
        SiteKeyHandle(publicKeyX963: k.publicKey.x963Representation, stored: k.rawRepresentation,
                      sign: { try k.signature(for: $0).rawRepresentation })
    }
}

public struct SecureEnclaveKeyBackend: SiteKeyBackend {
    public init() {}
    public var kind: UInt8 { 1 }
    public func create() throws -> SiteKeyHandle { Self.handle(try SecureEnclave.P256.Signing.PrivateKey()) }
    public func restore(_ stored: Data) throws -> SiteKeyHandle {
        Self.handle(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored))
    }
    private static func handle(_ k: SecureEnclave.P256.Signing.PrivateKey) -> SiteKeyHandle {
        SiteKeyHandle(publicKeyX963: k.publicKey.x963Representation, stored: k.dataRepresentation,
                      sign: { try k.signature(for: $0).rawRepresentation })
    }
}

/// This Mac's publishing key: Secure Enclave where available, else a software key stored the same way in
/// `<folder>/site-key` (0600). A missing, corrupt or unusable file makes a new key (never a crash); if a file
/// existed, `wasReplaced` is true and the UI shows `lostKeyNote`.
public final class SiteKey: RunSigner {
    public static let lostKeyNote =
        "This Mac's publishing key was replaced, so runs published before can no longer be removed from this Mac."

    public let publicKeyX963: Data
    public let wasReplaced: Bool
    private let signer: @Sendable (Data) throws -> Data

    private init(_ h: SiteKeyHandle, wasReplaced: Bool) {
        publicKeyX963 = h.publicKeyX963; signer = h.sign; self.wasReplaced = wasReplaced
    }

    public func sign(_ message: Data) throws -> Data { try signer(message) }

    public static var automaticBackend: any SiteKeyBackend {
        SecureEnclave.isAvailable ? SecureEnclaveKeyBackend() : SoftwareKeyBackend()
    }

    public static func loadOrCreate(in folder: URL, backend: any SiteKeyBackend = SiteKey.automaticBackend) throws -> SiteKey {
        let fm = FileManager.default
        let file = folder.appendingPathComponent("site-key")
        var existed = false
        if fm.fileExists(atPath: file.path) {
            existed = true
            // Unreadable is not corrupt: throw and leave the file alone.
            let data = try Data(contentsOf: file)
            if data.count > 1, data[data.startIndex] == backend.kind,
               let h = try? backend.restore(Data(data.dropFirst())) {
                return SiteKey(h, wasReplaced: false)
            }
            // Judged corrupt or unusable: keep it (never delete) so a wrongly judged key can be recovered.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            var backup = folder.appendingPathComponent("site-key.replaced-\(f.string(from: Date()))")
            var n = 1
            while fm.fileExists(atPath: backup.path) {
                n += 1
                backup = folder.appendingPathComponent("site-key.replaced-\(f.string(from: Date()))-\(n)")
            }
            try fm.moveItem(at: file, to: backup)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let h = try backend.create()
        // 0600 from creation, then an atomic rename: the private key is never world-readable.
        let tmp = folder.appendingPathComponent("site-key.tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: Data([backend.kind]) + h.stored,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { try fm.moveItem(at: tmp, to: file) } catch { try? fm.removeItem(at: tmp); throw error }
        return SiteKey(h, wasReplaced: existed)
    }
}
