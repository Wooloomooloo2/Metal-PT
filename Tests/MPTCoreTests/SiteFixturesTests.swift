import CryptoKit
import Foundation
import Testing
@testable import MPTCore

/// The committed golden runs (`Tests/Fixtures/site/`) must still produce the numbers the website's fixtures
/// (`web/test/fixtures/<name>/expected.json`, made by `scripts/make-site-fixtures.sh`) were generated with.
@Suite struct SiteFixturesTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: ["system-warmup", "no-warmup", "gpu-only", "capped-60"])
    func summaryMatchesExpected(name: String) throws {
        let run = Self.repo.appendingPathComponent("Tests/Fixtures/site/\(name)")
        let bundle = try RunBundle.load(run)
        #expect(bundle.info.graphics?.isComplete == true)
        let expectedURL = Self.repo.appendingPathComponent("web/test/fixtures/\(name)/expected.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: Any]
        // publisherVersion is the app that generated the fixtures (it moves with each release; the numbers don't).
        #expect(expected["publisherVersion"] is String, "\(name): publisherVersion")
        let summary = SiteSummary(bundle: bundle, publisherVersion: expected["publisherVersion"] as? String)
        let mine = try JSONSerialization.jsonObject(with: summary.encoded()) as! [String: Any]
        for (k, v) in mine {
            #expect(NSDictionary(dictionary: [k: v]).isEqual(to: [k: expected[k] ?? NSNull()]), "\(name): \(k)")
        }
        for k in ["key", "keyID", "timestamp", "signature"] { #expect(expected[k] is String, "\(name): \(k)") }
    }

    /// Drift check: the committed parts are the ones headers.json signed (a part edited or regenerated without the
    /// others would fail the site's tests with a confusing signature error), and expected.json's keyID is the key's.
    @Test(arguments: ["system-warmup", "no-warmup", "gpu-only", "capped-60"])
    func headersSignTheCommittedParts(name: String) throws {
        let dir = Self.repo.appendingPathComponent("web/test/fixtures/\(name)")
        func file(_ f: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(f)) }
        func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let headers = try JSONSerialization.jsonObject(with: file("headers.json")) as! [String: String]
        let expected = try JSONSerialization.jsonObject(with: file("expected.json")) as! [String: Any]
        let key = try #require(headers["key"].flatMap(Self.base64url))
        let sig = try #require(headers["signature"].flatMap(Self.base64url))
        let timestamp = try #require(headers["timestamp"])
        let message = SiteSigning.publishMessage(bundle: hex(try file("bundle.zip")), run: hex(try file("run.json")),
                                                 samples: hex(try file("samples.csv")),
                                                 summary: hex(try file("summary.json")), timestamp: timestamp)
        let pub = try P256.Signing.PublicKey(x963Representation: key)
        #expect(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: message), "\(name)")
        #expect(expected["keyID"] as? String == SiteSigning.keyID(publicKeyX963: key), "\(name): keyID")
        #expect(expected["key"] as? String == headers["key"], "\(name): key")
    }

    private static func base64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
