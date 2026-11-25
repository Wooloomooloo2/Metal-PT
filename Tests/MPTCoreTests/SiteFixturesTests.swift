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
        let mine = try JSONSerialization.jsonObject(with: SiteSummary(bundle: bundle).encoded()) as! [String: Any]
        let expectedURL = Self.repo.appendingPathComponent("web/test/fixtures/\(name)/expected.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: Any]
        for (k, v) in mine {
            #expect(NSDictionary(dictionary: [k: v]).isEqual(to: [k: expected[k] ?? NSNull()]), "\(name): \(k)")
        }
        for k in ["key", "keyID", "timestamp", "signature"] { #expect(expected[k] is String, "\(name): \(k)") }
    }
}
