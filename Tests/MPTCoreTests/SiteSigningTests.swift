import Testing
import Foundation
import CryptoKit
@testable import MPTCore

@Suite struct SiteSigningTests {
    @Test func publishMessageIsByteExact() {
        let m = SiteSigning.publishMessage(bundle: "aa", run: "bb", samples: "cc", summary: "dd",
                                           timestamp: "2026-11-25T10:00:00Z")
        #expect(String(decoding: m, as: UTF8.self) == "metal-pt-run\naa\nbb\ncc\ndd\n2026-11-25T10:00:00Z")
    }

    @Test func patchAndDeleteMessagesAreByteExact() {
        #expect(String(decoding: SiteSigning.patchMessage(id: "abc", bodySHA256: "ff", timestamp: "T"), as: UTF8.self)
                == "metal-pt-patch\nabc\nff\nT")
        #expect(String(decoding: SiteSigning.deleteMessage(id: "abc", timestamp: "T"), as: UTF8.self)
                == "metal-pt-delete\nabc\nT")
    }

    @Test func base64urlHasNoPaddingAndUrlAlphabet() {
        #expect(SiteSigning.base64url(Data([0xfb, 0xff, 0xfe])) == "-__-")
        #expect(SiteSigning.base64url(Data([0x01])) == "AQ")
        #expect(SiteSigning.base64url(Data([0x01, 0x02])) == "AQI")
    }

    @Test func timestampIsUTCSeconds() {
        #expect(SiteSigning.timestamp(Date(timeIntervalSince1970: 0.9)) == "1970-01-01T00:00:00Z")
        #expect(SiteSigning.timestamp(Date(timeIntervalSince1970: 1_795_600_000)) == "2026-11-25T09:46:40Z")
    }

    @Test func keyIDIsFirst16HexOfSHA256() {
        let key = Data([1, 2, 3])
        let full = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        #expect(SiteSigning.keyID(publicKeyX963: key) == String(full.prefix(16)))
        #expect(SiteSigning.keyID(publicKeyX963: key).count == 16)
    }

    @Test func softwareSignatureVerifiesRaw64Bytes() throws {
        let signer = SoftwareSigner(key: P256.Signing.PrivateKey())
        let msg = SiteSigning.deleteMessage(id: "x", timestamp: "T")
        let sig = try signer.sign(msg)
        #expect(sig.count == 64)
        let pub = try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963)
        #expect(signer.publicKeyX963.count == 65)
        #expect(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: msg))
        #expect(!pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: Data("other".utf8)))
    }

    @Test func softwareSignerInitFromRawKey() throws {
        let k = P256.Signing.PrivateKey()
        let s = try SoftwareSigner(rawKey: k.rawRepresentation)
        #expect(s.publicKeyX963 == k.publicKey.x963Representation)
        #expect(throws: (any Error).self) { try SoftwareSigner(rawKey: Data([1, 2])) }
    }
}
