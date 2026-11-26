import Foundation
import MPTApp
import MPTCore

/// `mpt publish` / `mpt unpublish`: the app's Publish and "Remove from metal-pt.com…", with the same publishing key
/// (`~/Library/Application Support/Metal-PT/site-key`). The run's page is recorded in its folder (`site.json`), as
/// the app does.
enum PublishCommands {
    static let usage = """
        publish RUN [--notes] [--force] [--runs DIR] [--site URL]
                                       publish RUN to metal-pt.com (or --site URL, else $MPT_SITE_URL) and print
                                       its page; notes are left out unless --notes; the graphics settings must be
                                       set (Edit Settings/Notes… in the app); refuses runs with no end time unless
                                       --force; RUN as for export
        unpublish RUN|ID [--runs DIR] [--site URL]
                                       remove a run this Mac published (by its folder, or the site's run id)
        """

    /// Hidden `--key-dir DIR`: use (or create) the key in DIR instead of Application Support (tests, local checks).
    static func publish(_ args: [String]) async throws {
        var notes = false, force = false, runs: String?, site: String?, keyDir: String?, run: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--notes": notes = true
            case "--force": force = true
            case "--runs", "--site", "--key-dir":
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                switch a {
                case "--runs": runs = args[i + 1]
                case "--site": site = args[i + 1]
                default: keyDir = args[i + 1]
                }
                i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard run == nil else { throw UsageError("publish takes one run, got '\(a)' too") }
                run = a
            }
            i += 1
        }
        guard let run else { throw UsageError("publish needs a run") }
        let url = try RecordCommands.locateRun(run, out: runs)
        let bundle = try RunBundle.load(url, frames: true)
        if bundle.info.end == nil && !force {
            throw BenchError("this run has no end time: it may still be recording (or was cut off); "
                             + "publish it once it has stopped, or pass --force")
        }
        if bundle.info.graphics?.isComplete != true {
            printError("note: the graphics settings are incomplete; metal-pt.com will refuse the run")
        }
        let client = try client(site: site, keyDir: keyDir)
        let payload = try PublishPayload.make(bundle, includeNotes: notes)
        let published = try await client.publish(payload)
        try SiteRecord(id: published.id, url: published.url).write(to: url)
        if published.alreadyPublished { print("already published (\(published.id)):") }
        if let notice = published.notice { printError(notice) }
        print(published.url.absoluteString)
    }

    static func unpublish(_ args: [String]) async throws {
        var runs: String?, site: String?, keyDir: String?, target: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--runs", "--site", "--key-dir":
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                switch a {
                case "--runs": runs = args[i + 1]
                case "--site": site = args[i + 1]
                default: keyDir = args[i + 1]
                }
                i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard target == nil else { throw UsageError("unpublish takes one run, got '\(a)' too") }
                target = a
            }
            i += 1
        }
        guard let target else { throw UsageError("unpublish needs a run or a run id") }
        // A run folder with a site.json, else the site's id itself.
        let folder = try? RecordCommands.locateRun(target, out: runs)
        let record = folder.flatMap(SiteRecord.read)
        if folder != nil && record == nil {
            throw BenchError("this run is not published from this Mac (no \(SiteRecord.fileName) in its folder)")
        }
        let id = record?.id ?? target
        do {
            try await client(site: site, keyDir: keyDir).remove(id: id)
        } catch let e as SiteError where e.isNotFound {
            printError(e.message)
        }
        if let folder { try SiteRecord.remove(from: folder) }
        print("removed \(id)")
    }

    private static func client(site: String?, keyDir: String?) throws -> SiteClient {
        let base: URL
        if let site {
            guard let u = SiteClient.override(["MPT_SITE_URL": site]) else {
                throw UsageError("--site needs an http(s) URL, got '\(site)'")
            }
            base = u
        } else {
            base = SiteClient.override(ProcessInfo.processInfo.environment) ?? SiteClient.defaultBase
        }
        let folder = try keyDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? AppFolders.support()
        let key = try SiteKey.loadOrCreate(in: folder)
        if key.wasReplaced { printError(SiteKey.lostKeyNote) }
        return SiteClient(base: base, signer: key)
    }
}
