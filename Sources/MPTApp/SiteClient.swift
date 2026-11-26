import CryptoKit
import Foundation
import MPTCore

/// Sends one HTTP request and returns the reply, whatever its status (an error only when no reply arrived).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a site request failed. `message` is shown to the user as is: the site's own text for a refusal, else ours.
public struct SiteError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    /// The site's error code (`errors.ts`), nil when the reply was not the site's JSON.
    public var code: String?
    /// HTTP status, nil when no reply arrived.
    public var status: Int?

    public init(message: String, code: String? = nil, status: Int? = nil) {
        self.message = message; self.code = code; self.status = status
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public static let offline = SiteError(message: "Can't reach metal-pt.com — try again later")

    /// The run is not on the site (404): already removed, or never there.
    public var isNotFound: Bool { status == 404 }

    /// The site refused because another key published the run (403 `not_yours`): this Mac's key was replaced.
    public var isNotYours: Bool { code == "not_yours" }
}

/// The website's signed API (spec §4.B): publish a run, change its video link, remove it. Every request carries
/// `MPT-Key` (the public key, base64url X9.63), `MPT-Timestamp` and `MPT-Signature` (base64url raw r‖s) over the
/// `SiteSigning` message; a publish also carries `MPT-Bundle-SHA256`.
public struct SiteClient: Sendable {
    /// A run on the website: its id and page. `alreadyPublished`: the site already had this exact bundle (409) and
    /// these are the first upload's id and page. `notice`: the site published it but says something (e.g. the video
    /// link was left out, and why).
    public struct Published: Equatable, Sendable {
        public var id: String
        public var url: URL
        public var alreadyPublished: Bool
        public var notice: String?

        public init(id: String, url: URL, alreadyPublished: Bool = false, notice: String? = nil) {
            self.id = id; self.url = url; self.alreadyPublished = alreadyPublished; self.notice = notice
        }
    }

    /// The staging site until production is approved; set to https://metal-pt.com when going live (with isLive).
    public static let defaultBase = URL(string: "https://metal-pt-staging.yh7mm4fp8v.workers.dev")!

    /// flip when metal-pt.com production is live. While false, release builds of the app hide everything that talks
    /// to the site (Publish, Remove, "Open on metal-pt.com", the edit sheet's video sync, "Offer to publish after
    /// each run"); "Export file…" stays. Debug builds, and `mpt publish` with `--site` or `MPT_SITE_URL`, still work.
    public static let isLive: Bool = false

    /// Which build this code is part of.
    public enum BuildKind: Sendable { case debug, release }

    public static var currentBuild: BuildKind {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    /// Whether publishing is offered (see `isLive`). `siteOverride`: a site was named explicitly (`mpt --site` or
    /// `MPT_SITE_URL`); the app passes false (its release builds ignore `MPT_SITE_URL`).
    public static func publishingAvailable(isLive: Bool = SiteClient.isLive, build: BuildKind = SiteClient.currentBuild,
                                           siteOverride: Bool) -> Bool {
        isLive || build == .debug || siteOverride
    }

    /// The app's gate: publishing UI shown in debug builds, or once `isLive`.
    public static func appPublishingAvailable(isLive: Bool = SiteClient.isLive,
                                              build: BuildKind = SiteClient.currentBuild) -> Bool {
        publishingAvailable(isLive: isLive, build: build, siteOverride: false)
    }

    /// `mpt publish`/`unpublish`'s gate: `--site URL` or `MPT_SITE_URL` (any build), a debug build, or `isLive`.
    public static func cliPublishingAvailable(site: String?, env: [String: String], isLive: Bool = SiteClient.isLive,
                                              build: BuildKind = SiteClient.currentBuild) -> Bool {
        let named = site != nil || override(env) != nil
        return publishingAvailable(isLive: isLive, build: build, siteOverride: named)
    }

    /// The app's site: `MPT_SITE_URL` in debug builds (staging or a local `cf dev`), else `defaultBase`.
    public static func appBase(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if DEBUG
        return override(env) ?? defaultBase
        #else
        return defaultBase
        #endif
    }

    /// `MPT_SITE_URL` when it is an http(s) URL with a host.
    public static func override(_ env: [String: String]) -> URL? {
        guard let text = env["MPT_SITE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    public let base: URL
    private let signer: RunSigner
    private let session: HTTPTransport
    private let now: @Sendable () -> Date
    private let boundary: @Sendable () -> String

    /// The default transport: ephemeral (no cookies, no cache, nothing written to disk).
    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    public init(base: URL, signer: RunSigner, session: HTTPTransport = SiteClient.defaultSession,
                now: @escaping @Sendable () -> Date = Date.init,
                boundary: @escaping @Sendable () -> String = { "metal-pt-\(UUID().uuidString)" }) {
        self.base = base; self.signer = signer; self.session = session; self.now = now; self.boundary = boundary
    }

    // MARK: - Calls

    /// `POST /api/v1/runs`. 201 → the new run; 409 with an id and url → that run, `alreadyPublished`.
    public func publish(_ p: PublishPayload) async throws -> Published {
        let h = p.hashes()
        let timestamp = SiteSigning.timestamp(now())
        let signature = try signer.sign(SiteSigning.publishMessage(bundle: h.bundle, run: h.run, samples: h.samples,
                                                                   summary: h.summary, timestamp: timestamp))
        let b = boundary()
        var request = URLRequest(url: endpoint("api/v1/runs"))
        request.httpMethod = "POST"
        request.httpBody = Self.multipart(boundary: b, parts: [
            .init(name: "bundle", filename: "run.mptrun.zip", contentType: "application/zip", data: p.bundleZip),
            .init(name: "run.json", filename: "run.json", contentType: "application/json", data: p.runJSON),
            .init(name: "samples.csv", filename: "samples.csv", contentType: "text/csv", data: p.samplesCSV),
            .init(name: "summary.json", filename: "summary.json", contentType: "application/json", data: p.summaryJSON),
        ])
        request.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        request.setValue(h.bundle, forHTTPHeaderField: "MPT-Bundle-SHA256")
        sign(&request, timestamp: timestamp, signature: signature)
        request.timeoutInterval = 120

        let (data, response) = try await send(request)
        let reply = Self.decode(data)
        switch response.statusCode {
        case 201:
            guard let id = reply?.id, let url = reply?.url.flatMap(URL.init(string:)) else { throw unreadable(response) }
            return Published(id: id, url: url, notice: reply?.notice)
        case 409 where reply?.id != nil && reply?.url.flatMap(URL.init(string:)) != nil:
            return Published(id: reply!.id!, url: URL(string: reply!.url!)!, alreadyPublished: true)
        default:
            throw failure(response, reply)
        }
    }

    /// `PATCH /api/v1/runs/:id` with `{ "videoURL": … }` (nil or empty clears the link).
    public func setVideo(id: String, url: String?) async throws {
        let link = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try Self.videoBody(link?.isEmpty == false ? link : nil)
        let timestamp = SiteSigning.timestamp(now())
        let signature = try signer.sign(SiteSigning.patchMessage(id: id, bodySHA256: Self.hex(body),
                                                                 timestamp: timestamp))
        var request = URLRequest(url: try runEndpoint(id))
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sign(&request, timestamp: timestamp, signature: signature)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw failure(response, Self.decode(data)) }
    }

    /// `DELETE /api/v1/runs/:id`. A 404 throws a `SiteError` with `isNotFound` (the caller may treat it as gone).
    public func remove(id: String) async throws {
        let timestamp = SiteSigning.timestamp(now())
        let signature = try signer.sign(SiteSigning.deleteMessage(id: id, timestamp: timestamp))
        var request = URLRequest(url: try runEndpoint(id))
        request.httpMethod = "DELETE"
        sign(&request, timestamp: timestamp, signature: signature)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw failure(response, Self.decode(data)) }
    }

    // MARK: - Request building (internal for tests)

    struct Part {
        var name: String
        var filename: String
        var contentType: String
        var data: Data
    }

    /// RFC 7578 `multipart/form-data`; each part a file (so the site receives the bytes unchanged).
    static func multipart(boundary: String, parts: [Part]) -> Data {
        var body = Data()
        for p in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(p.name)\"; filename=\"\(p.filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(p.contentType)\r\n\r\n".utf8))
            body.append(p.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// `{"videoURL":"…"}` or `{"videoURL":null}`.
    static func videoBody(_ url: String?) throws -> Data {
        struct Body: Encodable {
            let videoURL: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(videoURL, forKey: .videoURL)
            }
            enum CodingKeys: String, CodingKey { case videoURL }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(Body(videoURL: url))
    }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: - Private

    private struct Reply: Decodable {
        var id: String?
        var url: String?
        var notice: String?
        var code: String?
        var message: String?
    }

    private static func decode(_ data: Data) -> Reply? { try? JSONDecoder().decode(Reply.self, from: data) }

    private func endpoint(_ path: String) -> URL { base.appendingPathComponent(path) }

    private func runEndpoint(_ id: String) throws -> URL {
        // Ids are the site's own (letters, digits, `-`, `_`); anything else would change the path.
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw SiteError(message: "That run's metal-pt.com id (\(id)) is not valid.")
        }
        return endpoint("api/v1/runs/\(id)")
    }

    private func sign(_ request: inout URLRequest, timestamp: String, signature: Data) {
        request.setValue(SiteSigning.base64url(signer.publicKeyX963), forHTTPHeaderField: "MPT-Key")
        request.setValue(timestamp, forHTTPHeaderField: "MPT-Timestamp")
        request.setValue(SiteSigning.base64url(signature), forHTTPHeaderField: "MPT-Signature")
        request.setValue("Metal-PT/\(MetalPTVersion.current)", forHTTPHeaderField: "User-Agent")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await session.send(request)
        } catch let e as URLError where e.code != .cancelled {
            throw SiteError.offline
        }
    }

    private func failure(_ response: HTTPURLResponse, _ reply: Reply?) -> SiteError {
        if let message = reply?.message, !message.isEmpty {
            return SiteError(message: message, code: reply?.code, status: response.statusCode)
        }
        return unreadable(response)
    }

    private func unreadable(_ response: HTTPURLResponse) -> SiteError {
        SiteError(message: "metal-pt.com gave an unexpected reply (HTTP \(response.statusCode)). Try again later.",
                  status: response.statusCode)
    }
}
