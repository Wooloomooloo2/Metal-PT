import Foundation
import MPTCore

/// Publish, remove and re-link runs of a runs folder on the website, keeping each run's `site.json` (via the
/// index) in step with the site. Blocking file work happens on the calling task: call off the main actor.
public struct SitePublisher: Sendable {
    public let client: SiteClient
    public let index: RunIndex

    public init(client: SiteClient, index: RunIndex) {
        self.client = client
        self.index = index
    }

    /// Builds the upload (`PublishPayload`: the export zip plus copies of run.json, samples.csv and summary.json),
    /// posts it and records the run's id and page. A 409 (this exact bundle is already on the site) records the
    /// first upload's page and returns it with `alreadyPublished`. Refuses a run in progress.
    public func publish(dir: String, includeNotes: Bool, hosts: [String]? = nil) async throws -> SiteClient.Published {
        guard !index.isInProgress(dir: dir) else { throw RunIndexError.inProgress }
        let bundle = try RunBundle.load(index.root.appendingPathComponent(dir), frames: true)
        let payload = try PublishPayload.make(bundle, includeNotes: includeNotes, hosts: hosts)
        let published = try await client.publish(payload)
        do {
            try index.setPublished(dir: dir, record: SiteRecord(id: published.id, url: published.url))
        } catch {
            // The run is on the site; publishing again gets a 409 with its page, which records it then.
            try? FileHandle.standardError.write(contentsOf: Data(
                "Metal-PT: published \(dir) as \(published.id) but could not record it: \(error)\n".utf8))
        }
        return published
    }

    /// Removes the run from the website (signed DELETE) and forgets its record. A run the site no longer has (404)
    /// is forgotten too.
    public func remove(dir: String) async throws {
        guard let record = index.published(dir: dir) else { throw RunIndexError.notPublished }
        do {
            try await client.remove(id: record.id)
        } catch let e as SiteError where e.isNotFound {
            // Already gone (removed on the site, or by a moderator): nothing left to remove.
        }
        try index.clearPublished(dir: dir)
    }

    /// Sends the run's video link (nil or empty clears it) to the website, for a published run.
    public func setVideo(dir: String, url: String?) async throws {
        guard let record = index.published(dir: dir) else { throw RunIndexError.notPublished }
        try await client.setVideo(id: record.id, url: url)
    }
}
