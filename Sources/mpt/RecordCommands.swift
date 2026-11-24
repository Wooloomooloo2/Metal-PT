import Foundation
import MPTCore

enum RecordCommands {
    static let usage = """
        record [--pid P | --name S] [--seconds N] [--warmup S] [--label TEXT] [--settings TEXT] [--notes TEXT]
                                       record telemetry + Metal HUD FPS until N seconds pass or Ctrl-C;
                                       follows the Metal process with the most frames unless --pid/--name;
                                       --warmup must be shorter than --seconds; --settings records the
                                       in-game settings, --notes anything else (both shown in the summary)
        run [--seconds N] [--warmup S] [--label TEXT] [--settings TEXT] [--notes TEXT] -- CMD ARGS...
                                       launch CMD with the HUD variables, record it and its per-frame times;
                                       stops at N seconds, when CMD exits or on Ctrl-C (CMD keeps running;
                                       it inherits SIGPIPE ignored so it survives mpt exiting)
        stack PID                      print the detected runtime / translator / graphics stack as JSON
        ls                             list recorded runs
        summary RUN [--open]           write RUN/summary.html (RUN: a .mptrun folder, or its name under the runs
                                       folder) and print its path; --open opens it
        (record/run/ls/summary also take --out DIR to use DIR instead of ~/Documents/Metal-PT/runs)
        """

    static let appVersion = "0.2.0-dev"
    static let noHUDHint = "no Metal HUD lines yet — run 'mpt hud on' and relaunch the game"

    // MARK: - record / run

    static func record(_ args: [String]) throws {
        let o = try parseOptions(args, allowed: ["--pid", "--name", "--seconds", "--warmup", "--label", "--settings",
                                                     "--notes", "--out"])
        if o["--pid"] != nil && o["--name"] != nil { throw UsageError("use --pid or --name, not both") }
        var follow = FollowRule.busiest
        var game: String?
        if let text = o["--pid"] {
            guard let pid = Int32(text), pid > 0 else { throw UsageError("--pid needs a process id") }
            follow = .pid(pid)
            game = ProcessNames.displayName(pid: pid).map(ProcessNames.exeName(fromArgv0:))
        } else if let name = o["--name"] {
            follow = .nameContains(name)
            game = name
        }
        let session = try Session(options: o, follow: follow, game: game)
        session.start(child: nil)
    }

    static func run(_ args: [String]) throws {
        guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else {
            throw UsageError("run needs -- CMD [ARGS...]")
        }
        let o = try parseOptions(Array(args[..<dash]), allowed: ["--seconds", "--warmup", "--label", "--settings",
                                                                          "--notes", "--out"])
        let command = Array(args[(dash + 1)...])
        let session = try Session(options: o, follow: .busiest,
                                  game: ProcessNames.exeName(fromArgv0: command[0]), seedIsGuess: true)
        session.start(child: command)
    }

    // MARK: - stack / ls

    static func stack(_ args: [String]) throws {
        guard args.count == 1, let pid = Int32(args[0]), pid > 0 else { throw UsageError("stack needs a PID") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(StackDetector.detect(pid: pid)), as: UTF8.self))
    }

    static func ls(_ args: [String]) throws {
        let o = try parseOptions(args, allowed: ["--out"])
        let root = try runsRoot(o["--out"], create: false)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".mptrun") }.sorted()
        guard !names.isEmpty else { print("no runs in \(root.path)"); return }
        var rows: [[String]] = [["RUN", "GAME", "STACK", "FPS", "DURATION"]]
        for name in names {
            guard let bundle = try? RunBundle.load(root.appendingPathComponent(name), frames: false) else {
                rows.append([name, "?", "?", "?", "unreadable run.json"])
                continue
            }
            let info = bundle.info
            let duration = info.end.map { formatDuration($0.timeIntervalSince(info.start)) } ?? "unfinished"
            let fps = HTML.number(RunSummary(bundle).medianFPS, digits: 1)
            rows.append([name, info.game.exe.isEmpty ? "-" : info.game.exe, describe(info.stack), fps, duration])
        }
        let last = rows[0].count - 1
        let widths = (0...last).map { c in rows.map { $0[c].count }.max() ?? 0 }
        for r in rows {
            print(r.enumerated().map { c, cell in
                if c == last { return cell }
                // FPS is right-aligned.
                let pad = String(repeating: " ", count: max(0, widths[c] - cell.count))
                return c == 3 ? pad + cell : cell + pad
            }.joined(separator: "  "))
        }
    }

    // MARK: - summary

    static func summary(_ args: [String]) throws {
        // Options may come before or after RUN: `--open` is a flag, `--out` takes a value, one positional is RUN.
        var open = false, out: String?, run: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--open": open = true
            case "--out":
                guard i + 1 < args.count else { throw UsageError("--out needs a value") }
                out = args[i + 1]; i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard run == nil else { throw UsageError("summary takes one run, got '\(a)' too") }
                run = a
            }
            i += 1
        }
        guard let run else { throw UsageError("summary needs a run") }
        let url = try SummaryReport.write(bundleAt: try locateRun(run, out: out))
        print(url.path)
        if open { try runTool("/usr/bin/open", [url.path]) }
    }

    /// A bundle folder path, or a folder name (with or without `.mptrun`) under the runs root.
    static func locateRun(_ run: String, out: String?) throws -> URL {
        func isBundle(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.appendingPathComponent("run.json").path) }
        let direct = URL(fileURLWithPath: (run as NSString).expandingTildeInPath, isDirectory: true)
        if isBundle(direct) { return direct }
        if !run.contains("/") {
            let root = try runsRoot(out, create: false)
            for name in [run, run + ".mptrun"] where isBundle(root.appendingPathComponent(name)) {
                return root.appendingPathComponent(name, isDirectory: true)
            }
        }
        throw BenchError("no run found at '\(run)' (no run.json there or under the runs folder)")
    }

    /// The stack as the summary shows it.
    static func describe(_ s: Stack) -> String { SummaryReport.stackLine(s) ?? "unknown" }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `--out DIR`, else `$MPT_DATA_ROOT/runs`, else `~/Documents/Metal-PT/runs`.
    static func runsRoot(_ out: String?, create: Bool) throws -> URL {
        let root = benchFolder("runs", override: out)
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        return root
    }
}
