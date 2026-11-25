import Foundation
import MPTCore

/// `mpt payload`: the four upload parts the app sends to metal-pt.com, written as files (golden fixtures for the site).
enum PayloadCommands {
    static let usage = """
        payload RUN --out DIR [--notes] [--runs DIR]
                                       write bundle.zip, run.json, samples.csv and summary.json (the publish payload;
                                       the last three are byte-identical to the copies in the zip) into DIR;
                                       notes are left out unless --notes
        """

    static func run(_ args: [String]) throws {
        var notes = false, out: String?, runs: String?, run: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--notes": notes = true
            case "--out", "--runs":
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                if a == "--out" { out = args[i + 1] } else { runs = args[i + 1] }
                i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard run == nil else { throw UsageError("payload takes one run, got '\(a)' too") }
                run = a
            }
            i += 1
        }
        guard let run else { throw UsageError("payload needs a run") }
        guard let out else { throw UsageError("payload needs --out DIR") }
        let bundle = try RunBundle.load(try RecordCommands.locateRun(run, out: runs), frames: true)
        let payload = try PublishPayload.make(bundle, includeNotes: notes)
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.bundleZip.write(to: dir.appendingPathComponent("bundle.zip"))
        try payload.runJSON.write(to: dir.appendingPathComponent("run.json"))
        try payload.samplesCSV.write(to: dir.appendingPathComponent("samples.csv"))
        try payload.summaryJSON.write(to: dir.appendingPathComponent("summary.json"))
        print(dir.path)
    }
}
