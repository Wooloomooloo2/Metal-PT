import Foundation
import Testing
import MPTCore
@testable import MPTApp

@Suite struct SitePublisherTests {
    /// A runs folder holding a copy of the `system-warmup` golden run.
    private func runsRoot() throws -> (root: URL, dir: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-publisher-\(UUID().uuidString)")
        let dir = "2026-11-20_12-00-00_fixture.mptrun"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SiteClientTests.repo.appendingPathComponent("Tests/Fixtures/site/system-warmup"),
                                         to: root.appendingPathComponent(dir))
        return (root, dir)
    }

    private func publisher(_ root: URL, _ stub: StubTransport) -> SitePublisher {
        SitePublisher(client: SiteClientTests.client(stub, signer: SoftwareSigner()), index: RunIndex(root: root))
    }

    @Test func publishRecordsTheRunsPageInTheIndex() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport(.http(201, #"{"id":"r_new","url":"https://site.test/run/r_new"}"#))
        let p = publisher(root, stub)
        let published = try await p.publish(dir: dir, includeNotes: false, hosts: [])
        #expect(published.id == "r_new")
        let e = try #require(p.index.entries().first)
        #expect(e.publishedID == "r_new")
        #expect(e.publishedURL?.absoluteString == "https://site.test/run/r_new")
        #expect(stub.requests.count == 1)
    }

    @Test func alreadyPublishedRecordsTheFirstRun() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport(.http(409, #"{"code":"already_published","message":"This run is already published.","id":"r_first","url":"https://site.test/run/r_first"}"#))
        let p = publisher(root, stub)
        let published = try await p.publish(dir: dir, includeNotes: false, hosts: [])
        #expect(published.alreadyPublished)
        #expect(p.index.published(dir: dir)?.id == "r_first")
    }

    @Test func refusedOrOfflinePublishRecordsNothing() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport(.http(429, #"{"code":"rate_limited","message":"Try again later."}"#),
                                 .fail(URLError(.notConnectedToInternet)))
        let p = publisher(root, stub)
        await #expect(throws: SiteError(message: "Try again later.", code: "rate_limited", status: 429)) {
            _ = try await p.publish(dir: dir, includeNotes: false, hosts: [])
        }
        await #expect(throws: SiteError.offline) { _ = try await p.publish(dir: dir, includeNotes: false, hosts: []) }
        #expect(p.index.published(dir: dir) == nil)
    }

    @Test func removeForgetsTheRecordAlsoWhenTheSiteHasNoSuchRun() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport(.http(200, #"{"id":"r1","deleted":true}"#),
                                 .http(404, #"{"code":"not_found","message":"gone"}"#),
                                 .http(403, #"{"code":"not_yours","message":"Only the Mac that published this run can change or remove it."}"#))
        let p = publisher(root, stub)
        let record = SiteRecord(id: "r1", url: URL(string: "https://site.test/run/r1")!)
        try p.index.setPublished(dir: dir, record: record)
        try await p.remove(dir: dir)
        #expect(stub.last?.url?.path == "/api/v1/runs/r1")
        #expect(p.index.published(dir: dir) == nil)
        try p.index.setPublished(dir: dir, record: record)
        try await p.remove(dir: dir)
        #expect(p.index.published(dir: dir) == nil)
        // Any other refusal keeps the record.
        try p.index.setPublished(dir: dir, record: record)
        await #expect(throws: SiteError.self) { try await p.remove(dir: dir) }
        #expect(p.index.published(dir: dir) == record)
    }

    @Test func unpublishedRunCannotBeRemovedOrRelinked() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport()
        let p = publisher(root, stub)
        await #expect(throws: RunIndexError.self) { try await p.remove(dir: dir) }
        await #expect(throws: RunIndexError.self) { try await p.setVideo(dir: dir, url: nil) }
        #expect(stub.requests.isEmpty)
    }

    @Test func setVideoPatchesThePublishedRun() async throws {
        let (root, dir) = try runsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport(.http(200, #"{"id":"r1"}"#))
        let p = publisher(root, stub)
        try p.index.setPublished(dir: dir, record: SiteRecord(id: "r1", url: URL(string: "https://site.test/run/r1")!))
        try await p.setVideo(dir: dir, url: "https://youtu.be/dQw4w9WgXcQ")
        #expect(stub.last?.httpMethod == "PATCH")
        #expect(stub.last?.url?.path == "/api/v1/runs/r1")
    }
}
