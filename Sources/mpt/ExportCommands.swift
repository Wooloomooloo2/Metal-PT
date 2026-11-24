import Foundation
import MPTCore

/// `mpt export`: the upload file the app's "Export file…" writes (RunExport), for testing the website without the app.
enum ExportCommands {
    static let usage = """
        export RUN [--notes] [--force] [--runs DIR] [--out DIR]
                                       write the upload file RUN.mptrun.zip (run.json, samples.csv, frames.csv,
                                       manifest.json; no summary.html) to ~/Documents/Metal-PT/exports or --out DIR
                                       and print its path; notes are left out unless --notes; RUN: a .mptrun folder,
                                       or its name under the runs folder (--runs DIR); refuses runs over 25 MB,
                                       and runs with no end time (may still be recording) unless --force
        """

    static func run(_ args: [String]) throws {
        var notes = false, force = false, out: String?, runs: String?, run: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--notes": notes = true
            case "--force": force = true
            case "--out", "--runs":
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                if a == "--out" { out = args[i + 1] } else { runs = args[i + 1] }
                i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard run == nil else { throw UsageError("export takes one run, got '\(a)' too") }
                run = a
            }
            i += 1
        }
        guard let run else { throw UsageError("export needs a run") }
        let bundle = try RunBundle.load(try RecordCommands.locateRun(run, out: runs), frames: false)
        if bundle.info.end == nil && !force {
            throw BenchError("this run has no end time: it may still be recording (or was cut off); "
                             + "export it once it has stopped, or pass --force to export it as it is")
        }
        let zip = try RunExport.write(bundle, includeNotes: notes, to: benchFolder("exports", override: out))
        print(zip.path)
    }
}
