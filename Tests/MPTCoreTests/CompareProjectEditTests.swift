import Testing
import Foundation
@testable import MPTCore

/// The project edits shared by `mpt compare` and the app's Compare page.
@Suite struct CompareProjectEditTests {
    private func project(_ n: Int, baseline: Int = 0) -> CompareProject {
        CompareProject(name: "p", baseline: baseline, runs: (1...n).map { .init(bundle: "r\($0).mptrun") })
    }

    @Test func addRefusesARunAlreadyIn() throws {
        var p = project(1)
        try p.add(bundle: "r2.mptrun", name: "two")
        #expect(p.runs.map(\.bundle) == ["r1.mptrun", "r2.mptrun"])
        #expect(p.runs[1].name == "two")
        #expect(throws: CompareProjectError.alreadyAdded(bundle: "r1.mptrun", project: "p")) {
            try p.add(bundle: "r1.mptrun")
        }
        #expect("\(CompareProjectError.alreadyAdded(bundle: "r1.mptrun", project: "p"))"
                == "'r1.mptrun' is already in 'p'")
    }

    @Test func removeKeepsTheBaselinePointingAtTheSameRun() throws {
        var p = project(3, baseline: 2)
        #expect(try p.remove(at: 0) == false)
        #expect(p.baseline == 1)
        #expect(p.runs[p.baseline].bundle == "r3.mptrun")
        #expect(try p.remove(at: 0) == false)   // a run before it again
        #expect(p.baseline == 0)

        var q = project(3, baseline: 0)
        #expect(try q.remove(at: 2) == false)   // after the baseline: unchanged
        #expect(q.baseline == 0)
        #expect(try q.remove(at: 0) == true)    // the baseline itself: run 1 takes over
        #expect(q.baseline == 0)
        #expect(q.runs.map(\.bundle) == ["r2.mptrun"])
    }

    @Test func removeAndBaselineCheckTheIndex() throws {
        var p = project(2)
        #expect(throws: CompareProjectError.runNumber(3, count: 2)) { try p.remove(at: 2) }
        #expect(throws: CompareProjectError.runNumber(0, count: 2)) { try p.setBaseline(-1) }
        try p.setBaseline(1)
        #expect(p.baseline == 1)
        #expect("\(CompareProjectError.runNumber(3, count: 2))" == "no run 3 (the project has runs 1 to 2)")
    }

    @Test func fileMayHoldOnlyTheSameProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-slot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(CompareProject.fileName(for: "HZD stacks"))
        try CompareProject.checkFile(url, isFreeFor: "HZD stacks")       // no file yet
        try CompareProject(name: "HZD stacks").save(to: url)
        try CompareProject.checkFile(url, isFreeFor: "HZD stacks")       // the same project
        #expect(throws: CompareProjectError.fileHoldsOther(file: "hzd-stacks.json", project: "HZD stacks")) {
            try CompareProject.checkFile(url, isFreeFor: "hzd  STACKS")
        }
        #expect("\(CompareProjectError.fileHoldsOther(file: "hzd-stacks.json", project: "HZD stacks"))"
                == "project file hzd-stacks.json already holds project 'HZD stacks'")
    }
}
