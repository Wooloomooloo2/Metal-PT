import Foundation
import FWCore

enum CompareCommands {
    static let usage = """
        compare ls                     list compare projects
        compare NAME                   list NAME's runs (numbered; * marks the baseline)
        compare NAME add RUN [--as TEXT] [RUN [--as TEXT]]...
                                       add runs to NAME (created if new); --as names the run before it
        compare NAME baseline N        compare against run N
        compare NAME remove N          take run N out of NAME (the run itself is kept)
        compare NAME report [--open]   write NAME's report (.html next to the project) and print its path
        (compare takes --projects DIR instead of ~/Documents/FW Benchmark/projects, and --out DIR for the runs
         folder as record/run/ls/summary do)
        """

    static func run(_ args: [String]) throws {
        // Split off the folder options (anywhere), keep the rest in order.
        var projectsDir: String?, out: String?, rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--projects" || a == "--out" {
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                if a == "--projects" { projectsDir = args[i + 1] } else { out = args[i + 1] }
                i += 2
                continue
            }
            rest.append(a)
            i += 1
        }
        let projects = projectsRoot(projectsDir)
        guard let name = rest.first, !name.hasPrefix("--") else { throw UsageError("compare needs ls or a project name") }
        if name == "ls" {
            guard rest.count == 1 else { throw UsageError("unexpected argument '\(rest[1])'") }
            return try list(projects)
        }
        let url = projects.appendingPathComponent(CompareProject.fileName(for: name))
        let exists = FileManager.default.fileExists(atPath: url.path)
        var project = exists ? try CompareProject.load(url) : CompareProject(name: name)
        let runsRoot = try RecordCommands.runsRoot(out, create: false)
        let tail = Array(rest.dropFirst(2))

        switch rest.count > 1 ? rest[1] : nil {
        case nil:
            guard exists else { throw BenchError("no project '\(name)' in \(projects.path)") }
            show(project, runsRoot: runsRoot)
        case "add":
            if exists, project.name != name {
                throw BenchError("project file \(url.lastPathComponent) already holds project '\(project.name)'")
            }
            var added = 0
            var k = 0
            while k < tail.count {
                let a = tail[k]
                if a == "--as" {
                    guard k + 1 < tail.count else { throw UsageError("--as needs a value") }
                    guard added > 0, !project.runs.isEmpty else { throw UsageError("--as goes after the run it names") }
                    project.runs[project.runs.count - 1].name = tail[k + 1]
                    k += 2
                    continue
                }
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                let dir = try RecordCommands.locateRun(a, out: out)
                let bundle = CompareProject.entryBundle(for: dir, runsRoot: runsRoot)
                if project.runs.contains(where: { $0.bundle == bundle }) {
                    throw BenchError("'\(bundle)' is already in '\(project.name)'")
                }
                project.runs.append(.init(bundle: bundle))
                added += 1
                k += 1
            }
            guard added > 0 else { throw UsageError("add needs at least one run") }
            try project.save(to: url)
            show(project, runsRoot: runsRoot)
        case "baseline", "remove":
            guard exists else { throw BenchError("no project '\(name)' in \(projects.path)") }
            guard tail.count == 1, let n = Int(tail[0]), n >= 1, n <= project.runs.count else {
                throw UsageError("\(rest[1]) needs a run number from 1 to \(project.runs.count)")
            }
            if rest[1] == "baseline" {
                project.baseline = n - 1
            } else {
                project.runs.remove(at: n - 1)
                if project.baseline == n - 1 {
                    project.baseline = 0
                    if !project.runs.isEmpty { print("baseline was removed — run 1 is now the baseline") }
                } else if project.baseline > n - 1 {
                    project.baseline -= 1
                }
            }
            try project.save(to: url)
            show(project, runsRoot: runsRoot)
        case "report":
            guard exists else { throw BenchError("no project '\(name)' in \(projects.path)") }
            var open = false
            for a in tail {
                guard a == "--open" else { throw UsageError("unexpected argument '\(a)'") }
                open = true
            }
            let report = try CompareReport.write(project: project, projectURL: url, runsRoot: runsRoot)
            print(report.path)
            if open { try runTool("/usr/bin/open", [report.path]) }
        case let other?:
            throw UsageError("unknown compare action '\(other)' (add, baseline, remove, report)")
        }
    }

    /// `--projects DIR`, else `~/Documents/FW Benchmark/projects`.
    static func projectsRoot(_ dir: String?) -> URL {
        if let dir { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("FW Benchmark/projects", isDirectory: true)
    }

    static func list(_ root: URL) throws {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard !files.isEmpty else { print("no projects in \(root.path)"); return }
        for f in files {
            guard let p = try? CompareProject.load(root.appendingPathComponent(f)) else {
                print("\(f)  (unreadable)")
                continue
            }
            print("\(p.name)  \(p.runs.count) run\(p.runs.count == 1 ? "" : "s")")
        }
    }

    static func show(_ project: CompareProject, runsRoot: URL) {
        print(project.name)
        guard !project.runs.isEmpty else { print("  no runs yet"); return }
        for (i, entry) in project.runs.enumerated() {
            let url = CompareProject.bundleURL(entry, runsRoot: runsRoot)
            let mark = i == project.baseline ? "*" : " "
            if let b = try? RunBundle.load(url, frames: false) {
                let fps = HTML.number(RunSummary(b).medianFPS, digits: 1)
                print("\(mark)\(i + 1)  \(CompareReport.label(entry, b.info))  \(fps) fps  \(entry.bundle)")
            } else {
                print("\(mark)\(i + 1)  \(entry.name.isEmpty ? "-" : entry.name)  missing  \(entry.bundle)")
            }
        }
    }
}
