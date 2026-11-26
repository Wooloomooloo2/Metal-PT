import CryptoKit
import Foundation
import Testing
import MPTCore
@testable import MPTApp

/// Records each request and answers with the next canned reply (or throws it).
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Reply { case http(Int, String), fail(URLError) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: Reply...) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .http(500, "") : replies.removeFirst()
        }
        switch reply {
        case .fail(let e): throw e
        case .http(let status, let body):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), r)
        }
    }

    var last: URLRequest? { lock.withLock { requests.last } }
}

@Suite struct SiteClientTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
    static let base = URL(string: "https://site.test")!

    static func payload() throws -> PublishPayload {
        let run = repo.appendingPathComponent("Tests/Fixtures/site/system-warmup")
        return try PublishPayload.make(try RunBundle.load(run, frames: true), includeNotes: false, hosts: [])
    }

    static func client(_ stub: StubTransport, signer: SoftwareSigner) -> SiteClient {
        SiteClient(base: base, signer: signer, session: stub, now: { fixedNow }, boundary: { "BOUNDARY" })
    }

    static func verifies(_ signer: SoftwareSigner, _ request: URLRequest, message: Data) throws -> Bool {
        let key = try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963)
        guard let sigText = request.value(forHTTPHeaderField: "MPT-Signature"),
              let sig = Data(base64urlEncoded: sigText), sig.count == 64 else { return false }
        return key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: message)
    }

    /// The parts of a multipart body: name → (headers, bytes).
    static func parts(_ body: Data, boundary: String) -> [String: (headers: String, data: Data)] {
        var out: [String: (String, Data)] = [:]
        let delimiter = Data("--\(boundary)".utf8)
        var chunks: [Data] = []
        var rest = body[...]
        while let r = rest.firstRange(of: delimiter) {
            chunks.append(Data(rest[..<r.lowerBound]))
            rest = rest[r.upperBound...]
        }
        for chunk in chunks.dropFirst() {
            // "\r\n<headers>\r\n\r\n<data>\r\n"
            guard let sep = chunk.firstRange(of: Data("\r\n\r\n".utf8)) else { continue }
            let headers = String(decoding: chunk[chunk.startIndex + 2..<sep.lowerBound], as: UTF8.self)
            let data = Data(chunk[sep.upperBound..<chunk.endIndex - 2])
            guard let n = headers.range(of: "name=\"")?.upperBound,
                  let e = headers[n...].firstIndex(of: "\"") else { continue }
            out[String(headers[n..<e])] = (headers, data)
        }
        return out
    }

    // MARK: - Publish

    @Test func publishSendsTheFourPartsAndSignedHeaders() async throws {
        let p = try Self.payload()
        let signer = SoftwareSigner()
        let stub = StubTransport(.http(201, #"{"id":"r_abc123","url":"https://site.test/run/r_abc123"}"#))
        let published = try await Self.client(stub, signer: signer).publish(p)
        #expect(published == SiteClient.Published(id: "r_abc123", url: URL(string: "https://site.test/run/r_abc123")!))

        let r = try #require(stub.last)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://site.test/api/v1/runs")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        let h = p.hashes()
        #expect(r.value(forHTTPHeaderField: "MPT-Bundle-SHA256") == h.bundle)
        #expect(r.value(forHTTPHeaderField: "MPT-Key") == SiteSigning.base64url(signer.publicKeyX963))
        #expect(r.value(forHTTPHeaderField: "MPT-Timestamp") == SiteSigning.timestamp(Self.fixedNow))
        let message = SiteSigning.publishMessage(bundle: h.bundle, run: h.run, samples: h.samples, summary: h.summary,
                                                 timestamp: SiteSigning.timestamp(Self.fixedNow))
        #expect(try Self.verifies(signer, r, message: message))
        #expect(try !Self.verifies(signer, r, message: message + Data("x".utf8)))

        let body = try #require(r.httpBody)
        #expect(body.suffix(14) == Data("--BOUNDARY--\r\n".utf8))
        let parts = Self.parts(body, boundary: "BOUNDARY")
        #expect(Set(parts.keys) == ["bundle", "run.json", "samples.csv", "summary.json"])
        #expect(parts["bundle"]?.data == p.bundleZip)
        #expect(parts["run.json"]?.data == p.runJSON)
        #expect(parts["samples.csv"]?.data == p.samplesCSV)
        #expect(parts["summary.json"]?.data == p.summaryJSON)
        #expect(parts["bundle"]?.headers ==
                "Content-Disposition: form-data; name=\"bundle\"; filename=\"run.mptrun.zip\"\r\nContent-Type: application/zip")
        #expect(parts["samples.csv"]?.headers.contains("filename=\"samples.csv\"") == true)
    }

    @Test func publishKeepsTheSiteNotice() async throws {
        let stub = StubTransport(.http(201, #"{"id":"r1","url":"https://site.test/run/r1","notice":"Published without the video link: private."}"#))
        let published = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
        #expect(published.notice == "Published without the video link: private.")
        #expect(!published.alreadyPublished)
    }

    @Test func conflictIsAlreadyPublishedWithTheFirstRun() async throws {
        let stub = StubTransport(.http(409, #"{"code":"already_published","message":"This run is already published.","id":"r_first","url":"https://site.test/run/r_first"}"#))
        let published = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
        #expect(published == SiteClient.Published(id: "r_first", url: URL(string: "https://site.test/run/r_first")!,
                                       alreadyPublished: true))
    }

    @Test func refusalShowsTheSiteMessageAsIs() async throws {
        let stub = StubTransport(.http(422, #"{"code":"missing_graphics","message":"Set the graphics preset before publishing."}"#))
        await #expect(throws: SiteError(message: "Set the graphics preset before publishing.", code: "missing_graphics",
                                        status: 422)) {
            _ = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
        }
    }

    @Test func nonJSONReplyIsAnUnexpectedReply() async throws {
        let stub = StubTransport(.http(502, "<html>Bad gateway</html>"))
        await #expect(throws: SiteError(message: "metal-pt.com gave an unexpected reply (HTTP 502). Try again later.",
                                        status: 502)) {
            _ = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
        }
    }

    @Test func createdWithoutAnIdIsUnexpected() async throws {
        let stub = StubTransport(.http(201, "{}"))
        await #expect(throws: SiteError.self) {
            _ = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
        }
    }

    @Test func offlineSaysSo() async throws {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut] {
            let stub = StubTransport(.fail(URLError(code)))
            await #expect(throws: SiteError.offline) {
                _ = try await Self.client(stub, signer: SoftwareSigner()).publish(try Self.payload())
            }
        }
        #expect(SiteError.offline.message == "Can't reach metal-pt.com — try again later")
    }

    // MARK: - Video link and remove

    @Test func setVideoSendsASignedPatch() async throws {
        let signer = SoftwareSigner()
        let stub = StubTransport(.http(200, #"{"id":"r1"}"#), .http(200, #"{"id":"r1"}"#))
        let client = Self.client(stub, signer: signer)
        try await client.setVideo(id: "r1", url: " https://youtu.be/dQw4w9WgXcQ ")
        var r = try #require(stub.last)
        #expect(r.httpMethod == "PATCH")
        #expect(r.url?.absoluteString == "https://site.test/api/v1/runs/r1")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "MPT-Bundle-SHA256") == nil)
        let body = try #require(r.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"videoURL":"https://youtu.be/dQw4w9WgXcQ"}"#)
        let ts = SiteSigning.timestamp(Self.fixedNow)
        #expect(try Self.verifies(signer, r, message: SiteSigning.patchMessage(id: "r1", bodySHA256: SiteClient.hex(body),
                                                                               timestamp: ts)))
        try await client.setVideo(id: "r1", url: "")
        r = try #require(stub.last)
        #expect(String(decoding: r.httpBody ?? Data(), as: UTF8.self) == #"{"videoURL":null}"#)
    }

    @Test func setVideoRefusalCarriesTheMessage() async throws {
        let stub = StubTransport(.http(422, #"{"code":"video_unavailable","message":"The video link was not saved: it is private."}"#))
        await #expect(throws: SiteError(message: "The video link was not saved: it is private.", code: "video_unavailable",
                                        status: 422)) {
            try await Self.client(stub, signer: SoftwareSigner()).setVideo(id: "r1", url: "https://youtu.be/dQw4w9WgXcQ")
        }
    }

    @Test func removeSendsASignedDelete() async throws {
        let signer = SoftwareSigner()
        let stub = StubTransport(.http(200, #"{"id":"r1","deleted":true}"#))
        try await Self.client(stub, signer: signer).remove(id: "r1")
        let r = try #require(stub.last)
        #expect(r.httpMethod == "DELETE")
        #expect(r.url?.absoluteString == "https://site.test/api/v1/runs/r1")
        #expect(r.httpBody == nil)
        #expect(try Self.verifies(signer, r, message: SiteSigning.deleteMessage(id: "r1",
                                                                                timestamp: SiteSigning.timestamp(Self.fixedNow))))
    }

    @Test func removeNotFoundAndNotYours() async throws {
        let stub = StubTransport(
            .http(404, #"{"code":"not_found","message":"That run is not on metal-pt.com (it may have been removed already)."}"#),
            .http(403, #"{"code":"not_yours","message":"Only the Mac that published this run can change or remove it."}"#))
        let client = Self.client(stub, signer: SoftwareSigner())
        do {
            try await client.remove(id: "r1")
            Issue.record("expected a 404")
        } catch let e as SiteError {
            #expect(e.isNotFound)
        }
        await #expect(throws: SiteError(message: "Only the Mac that published this run can change or remove it.",
                                        code: "not_yours", status: 403)) {
            try await client.remove(id: "r1")
        }
    }

    @Test func oddIdsAreRefusedBeforeSending() async throws {
        let stub = StubTransport()
        await #expect(throws: SiteError.self) { try await Self.client(stub, signer: SoftwareSigner()).remove(id: "../admin") }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - Base URL

    @Test func siteOverrideNeedsAnHTTPURL() {
        #expect(SiteClient.override(["MPT_SITE_URL": "http://localhost:8787"])?.absoluteString == "http://localhost:8787")
        #expect(SiteClient.override(["MPT_SITE_URL": "ftp://x"]) == nil)
        #expect(SiteClient.override(["MPT_SITE_URL": " "]) == nil)
        #expect(SiteClient.override([:]) == nil)
        #expect(SiteClient.defaultBase.absoluteString == "https://metal-pt.com")
    }

    @Test func defaultTransportKeepsNoCookiesOrCache() {
        let c = SiteClient.defaultSession.configuration
        #expect(c.httpCookieStorage == nil)
        #expect(!c.httpShouldSetCookies)
        #expect(c.urlCache == nil)
    }

    @Test func baseWithAPathKeepsIt() async throws {
        let stub = StubTransport(.http(200, "{}"))
        let client = SiteClient(base: URL(string: "https://site.test/staging")!, signer: SoftwareSigner(), session: stub)
        try await client.remove(id: "r1")
        #expect(stub.last?.url?.absoluteString == "https://site.test/staging/api/v1/runs/r1")
    }
}

extension Data {
    init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
