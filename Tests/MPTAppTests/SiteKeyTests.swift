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

    @Test func unreadableFileThrowsAndIsUntouched() throws {
        let dir = tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("site-key").path)
            try? FileManager.default.removeItem(at: dir)
        }
        _ = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        let file = dir.appendingPathComponent("site-key")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["site-key"])
    }

    @Test func corruptFileIsKeptAsReplacedBackup() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = Data([2, 9, 9, 9])
        try bad.write(to: dir.appendingPathComponent("site-key"))
        let k = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())
        #expect(k.wasReplaced)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = names.filter { $0.hasPrefix("site-key.replaced-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == bad)
        #expect(!names.contains { $0.contains(".tmp-") })
    }

    // MARK: - Replace only malformed or mismatched files (final review 5)

    /// A Secure-Enclave-like backend whose restore can be made to fail, as the enclave sometimes does.
    final class FlakyBackend: SiteKeyBackend, @unchecked Sendable {
        let soft = SoftwareKeyBackend()
        var failRestore = false
        var kind: UInt8 { 1 }
        var restoreMayFailTransiently: Bool { true }
        func create() throws -> SiteKeyHandle { try soft.create() }
        func restore(_ stored: Data) throws -> SiteKeyHandle {
            if failRestore { throw CocoaError(.coderReadCorrupt) }
            return try soft.restore(stored)
        }
    }

    @Test func enclaveRestoreFailureIsRetryableAndKeepsTheFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FlakyBackend()
        let a = try SiteKey.loadOrCreate(in: dir, backend: backend)
        let file = dir.appendingPathComponent("site-key")
        let before = try Data(contentsOf: file)
        backend.failRestore = true
        #expect(throws: SiteKeyUnavailable.self) { try SiteKey.loadOrCreate(in: dir, backend: backend) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["site-key"])
        // Next time it opens: the same key, not replaced.
        backend.failRestore = false
        let b = try SiteKey.loadOrCreate(in: dir, backend: backend)
        #expect(!b.wasReplaced)
        #expect(b.publicKeyX963 == a.publicKeyX963)
    }

    @Test func retryableMessage() {
        #expect(SiteKeyUnavailable(underlying: "x").localizedDescription
                == "This Mac's publishing key couldn't be opened just now — try again.")
    }

    @Test func storeDoesNotCacheAFailureSoATryAgainWorks() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FlakyBackend()
        let a = try SiteKey.loadOrCreate(in: dir, backend: backend)
        backend.failRestore = true
        let store = SiteKeyStore(folder: { dir }, backend: backend)
        #expect(throws: SiteKeyUnavailable.self) { _ = try store.key() }
        backend.failRestore = false
        let k = try store.key()
        #expect(!k.replaced)
        #expect(k.key.publicKeyX963 == a.publicKeyX963)
    }

    @Test func anotherBackendsKeyIsReplaced() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SiteKey.loadOrCreate(in: dir, backend: SoftwareKeyBackend())   // kind 2
        let backend = FlakyBackend()                                          // kind 1
        backend.failRestore = true   // never asked: the kind byte decides
        let k = try SiteKey.loadOrCreate(in: dir, backend: backend)
        #expect(k.wasReplaced)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasPrefix("site-key.replaced-") }.count == 1)
    }

    @Test func tooShortEnclaveFileIsReplaced() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("site-key"))
        let backend = FlakyBackend()
        backend.failRestore = true
        #expect(try SiteKey.loadOrCreate(in: dir, backend: backend).wasReplaced)
    }
}
