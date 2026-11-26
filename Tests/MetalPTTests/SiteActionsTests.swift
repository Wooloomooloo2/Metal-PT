import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
import MPTCore

/// Answers every request with one canned reply.
private final class FixedReply: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    init(_ status: Int, _ body: String) { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ v: Bool) { lock.withLock { values.append(v) } }
    var all: [Bool] { lock.withLock { values } }
}

@MainActor
@Suite struct SiteActionsTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A store over a runs folder holding the `system-warmup` golden run, marked published as `r1`.
    private func publishedStore(_ reply: FixedReply, calls: Flag = Flag()) throws -> (RunsStore, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-site-\(UUID().uuidString)")
        let dir = "2026-11-20_12-00-00_fixture.mptrun"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.repo.appendingPathComponent("Tests/Fixtures/site/system-warmup"),
                                         to: root.appendingPathComponent(dir))
        try SiteRecord(id: "r1", url: URL(string: "https://site.test/run/r1")!).write(to: root.appendingPathComponent(dir))
        let store = RunsStore()
        store.showFixture(root: root)
        store.makeSiteClient = {
            calls.add(Thread.isMainThread)
            return SiteClient(base: URL(string: "https://site.test")!, signer: SoftwareSigner(), session: reply)
        }
        return (store, dir, root)
    }

    // MARK: Video link refused (fix 1)

    @Test func videoLinkIsSentOnlyWhenPublishedAndChanged() {
        let a = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        #expect(!VideoLinkSync.needsSend(published: false, link: a, synced: ""))
        #expect(VideoLinkSync.needsSend(published: true, link: a, synced: ""))
        #expect(VideoLinkSync.needsSend(published: true, link: "", synced: a))
        #expect(!VideoLinkSync.needsSend(published: true, link: " \(a) ", synced: a))
        // Another spelling of the same video is not a change.
        #expect(!VideoLinkSync.needsSend(published: true, link: "https://youtu.be/dQw4w9WgXcQ", synced: a))
    }

    @Test func refusedLinkSaysItIsOnlyOnThisMacAndToRetry() async throws {
        let (store, dir, root) = try publishedStore(FixedReply(422, #"{"code":"video_unavailable","message":"The video link was not saved: that video is private."}"#))
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await store.setSiteVideo(dir, url: "https://youtu.be/dQw4w9WgXcQ")
            Issue.record("expected a refusal")
        } catch {
            #expect(VideoLinkSync.refusedMessage(error) == "The link was saved on this Mac but not on metal-pt.com: "
                    + "The video link was not saved: that video is private. Save again to retry.")
        }
        // The sheet keeps its synced value after a refusal, so the same link is still due on the next save.
        #expect(VideoLinkSync.needsSend(published: true, link: "https://youtu.be/dQw4w9WgXcQ", synced: ""))
    }

    // MARK: Remove refused as not_yours (fix 2)

    @Test func notYoursKeepsTheRecordUntilForgotten() async throws {
        let calls = Flag()
        let (store, dir, root) = try publishedStore(FixedReply(403, #"{"code":"not_yours","message":"Only the Mac that published this run can change or remove it."}"#), calls: calls)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await store.removeFromSite(dir)
            Issue.record("expected not_yours")
        } catch let e as SiteError {
            #expect(e.isNotYours)
            #expect(RunsPage.notYoursMessage(e).hasPrefix("Only the Mac that published this run can change or remove it. "))
            #expect(RunsPage.notYoursMessage(e).contains("Forget on this Mac"))
        }
        #expect(store.entry(dir)?.isPublished == true)
        try await store.forgetPublished(dir)
        #expect(store.entry(dir)?.isPublished == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).appendingPathComponent("site.json").path))
        // Fix 3: the client (and so the key) is made off the main actor.
        #expect(calls.all == [false])
    }

    @Test func otherRefusalsAreNotNotYours() {
        #expect(!SiteError(message: "x", code: "not_found", status: 404).isNotYours)
        #expect(SiteError(message: "x", code: "not_yours", status: 403).isNotYours)
    }
}
