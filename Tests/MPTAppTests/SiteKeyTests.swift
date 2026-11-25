import Testing
import Foundation
import CryptoKit
import MPTCore
@testable import MPTApp

@Suite struct SiteKeyTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mpt-sitekey-\(UUID().uuidString)")
    }

    @Test func createsThenReloadsSameKey() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        #expect(!a.wasReplaced)
        let file = dir.appendingPathComponent("site-key")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let b = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        #expect(!b.wasReplaced)
        #expect(a.publicKeyX963 == b.publicKeyX963)
        let sig = try b.sign(Data("m".utf8))
        let pub = try P256.Signing.PublicKey(x963Representation: a.publicKeyX963)
        #expect(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: Data("m".utf8)))
    }

    @Test func corruptFileMakesNewKeyAndFlagsReplaced() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("site-key"))
        let b = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        #expect(b.wasReplaced)
        #expect(a.publicKeyX963 != b.publicKeyX963)
        let c = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        #expect(!c.wasReplaced)
        #expect(c.publicKeyX963 == b.publicKeyX963)
    }

    @Test func emptyFileIsReplacedToo() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("site-key"))
        #expect(try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend()).wasReplaced)
    }

    @Test func lostKeyNoteText() {
        #expect(SiteKey.lostKeyNote == "This Mac's publishing key was replaced, so runs published before can no longer be removed from this Mac.")
    }
}
