import Testing
import Foundation
import SystemConfiguration
@testable import MPTCore

@Suite struct RunBundleTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mptrun-\(UUID().uuidString)")
    }
    private func info(notes: String = "") -> RunInfo {
        RunInfo(appVersion: "0.1", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", gpuCores: 14,
                                                  memoryGB: 36, osVersion: "15.1", osBuild: "24B83"),
                game: .init(exe: "hzd.exe"), stack: Stack(runtime: "Protium", graphics: ["DXMT"]),
                user: .init(label: "a", gameSettings: "high", notes: notes),
                start: Date(timeIntervalSince1970: 1_800_000_000), fpsSource: "log")
    }

    @Test func roundTripsBundle() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        for i in 0..<3 { try w.append(sample: ["t": "t\(i)", "fps": "60.0", "fps_app": "a,\"b\"", "bogus": "x"]) }
        let frames = (1...5).map { FrameTime(intervalMs: Double($0), presentDelayMs: 0.5) }
        try w.append(frames: frames, endingAtMs: 1000)
        let end = Date(timeIntervalSince1970: 1_800_000_100)
        try w.finish { $0.end = end; $0.steadyStartS = 10 }
        let b = try RunBundle.load(dir)
        #expect(b.rows.count == 3)
        #expect(b.rows[1]["t"] == "t1")
        #expect(b.rows[0]["fps_app"] == "a,\"b\"")
        #expect(b.rows[0]["gpu_w"] == "")
        #expect(b.frames?.count == 5)
        #expect(b.frames?.last == TimedFrame(tMs: 1000, intervalMs: 5, presentDelayMs: 0.5))
        #expect(b.info.end == end)
        #expect(b.info.steadyStartS == 10)
        #expect(b.info.machine.gpuCores == 14)
    }

    /// `loadInfo` reads run.json only: an unreadable samples.csv does not matter (and adds no warning), while the
    /// newer-schema warning is kept.
    @Test func loadInfoReadsOnlyRunJSON() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        var newer = info()
        newer.schema = RunInfo.currentSchema + 1
        let w = try RunBundleWriter(directory: dir, info: newer)
        try w.append(sample: ["fps": "60"])
        try w.finish { _ in }
        let samples = dir.appendingPathComponent("samples.csv")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: samples.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: samples.path) }
        #expect(try RunBundle.load(dir).warnings.contains("samples.csv missing"))
        let loaded = try RunBundle.loadInfo(dir)
        #expect(loaded.game.exe == "hzd.exe")
        #expect(loaded.user.gameSettings == "high")
        #expect(loaded.warnings == ["newer bundle format (schema \(RunInfo.currentSchema + 1))"])
        #expect(throws: (any Error).self) { try RunBundle.loadInfo(dir.appendingPathComponent("nope")) }
    }

    @Test func framesGetTimesBackwardsFromArrival() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        try w.append(frames: [10, 20, 30].map { FrameTime(intervalMs: $0, presentDelayMs: 1) }, endingAtMs: 1000)
        try w.finish { _ in }
        let b = try RunBundle.load(dir)
        #expect(b.frames?.map(\.tMs) == [950, 970, 1000])
        let text = try String(contentsOf: dir.appendingPathComponent("frames.csv"), encoding: .utf8)
        #expect(text.hasPrefix("t_ms,interval_ms,present_delay_ms\n"))
    }

    @Test func renameMovesPlaceholderBundle() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = RunBundle.availableDirectory(in: root, start: start, game: "run")
        let w = try RunBundleWriter(directory: dir, info: info())
        try w.finish { _ in }
        // Another bundle already holds the game's name: the rename picks the next free one.
        let taken = root.appendingPathComponent(RunBundle.directoryName(start: start, game: "HZD.exe"))
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: taken.appendingPathComponent("run.json"))
        let moved = try RunBundle.rename(dir, start: start, game: "HZD.exe")
        #expect(moved.lastPathComponent == "20270115-080000-hzd-exe-2.mptrun")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("samples.csv").path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Already under the game's name: nothing moves.
        let again = try RunBundle.rename(taken, start: start, game: "HZD.exe")
        #expect(again == taken)
    }

    @Test func numbersUsePOSIXDecimal() {
        #expect(CSV.number(1.5, digits: 2) == "1.50")
        #expect(CSV.number(1234.5, digits: 1) == "1234.5")
        #expect(CSV.number(nil, digits: 1) == "")
        #expect(SampleColumns.format(59.94, column: "fps") == "59.9")
        #expect(SampleColumns.format(16.666, column: "ft_p99_ms") == "16.67")
        #expect(SampleColumns.format(2345.6, column: "fan0_rpm") == "2346")
        #expect(SampleColumns.format(80.4, column: "battery_pct") == "80")
        #expect(SampleColumns.format(12.346, column: "gpu_w") == "12.35")
        #expect(SampleColumns.format(7.26, column: "elapsed_s") == "7.3")
        #expect(SampleColumns.format(1234.0, column: "fps_pid") == "1234")
        #expect(CSV.number(-0.001, digits: 2) == "0.00")
        #expect(SampleColumns.format(onAC: true) == "1")
        #expect(SampleColumns.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }

    @Test func csvQuotesRoundTrip() {
        let line = CSV.line(["a", "x,y", "say \"hi\""])
        #expect(line == "a,\"x,y\",\"say \"\"hi\"\"\"")
        let rows = CSV.parse("p,q,r\n" + line + "\n")
        #expect(rows == [["p": "a", "q": "x,y", "r": "say \"hi\""]])
    }

    @Test func loadCanSkipFrames() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        try w.append(frames: [FrameTime(intervalMs: 16, presentDelayMs: 1)], endingAtMs: 1000)
        try w.finish { _ in }
        #expect(try RunBundle.load(dir).frames?.count == 1)
        #expect(try RunBundle.load(dir, frames: false).frames == nil)
    }

    @Test func loadsBundleWithMissingPieces() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        try w.finish { _ in }
        var json = try String(contentsOf: dir.appendingPathComponent("run.json"), encoding: .utf8)
        json = json.replacingOccurrences(of: "\"schema\" : 1", with: "\"schema\" : 2")
        try json.write(to: dir.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)
        try "t,fps,future_col\n2026-01-01T00:00:00.000Z,30.0,zzz\n".write(
            to: dir.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
        let b = try RunBundle.load(dir)
        #expect(b.frames == nil)
        #expect(b.rows.count == 1)
        #expect(b.rows[0]["gpu_w"] == nil)
        #expect(b.rows[0]["future_col"] == "zzz")
        #expect(b.warnings.contains("newer bundle format (schema 2)"))
    }

    @Test func scrubsHomePaths() {
        #expect(Privacy.scrub("/Users/alice/Games/x.exe") == "~/Games/x.exe")
        let scrubbed = Privacy.scrub(info(notes: "see /Users/bob/notes"))
        #expect(scrubbed.user.notes == "see ~/notes")
    }

    @Test func directoryNameSlug() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 24; c.hour = 12; c.minute = 24
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: c)!
        #expect(RunBundle.directoryName(start: d, game: "Horizon Zero Dawn™ Remastered.exe")
                == "20261124-122400-horizon-zero-dawn-remastered-exe.mptrun")
        #expect(RunBundle.slug(String(repeating: "ab ", count: 30)).count <= 40)
        #expect(!RunBundle.slug(String(repeating: "ab ", count: 30)).hasSuffix("-"))
    }

    @Test func finishIsIdempotentAndClosesFiles() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        var calls = 0
        try w.finish { $0.end = Date(timeIntervalSince1970: 1_800_000_050); calls += 1 }
        try w.finish { $0.end = Date(timeIntervalSince1970: 1_900_000_000); calls += 1 }
        try w.append(sample: ["t": "late"])
        #expect(calls == 1)
        let b = try RunBundle.load(dir)
        #expect(b.info.end == Date(timeIntervalSince1970: 1_800_000_050))
        #expect(b.rows.isEmpty)
    }

    @Test func scrubsEveryStringFieldInWrittenRunJSON() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let p = "/Users/someone/x"
        var i = info()
        i.game = .init(exe: p, title: p, storeAppID: p)
        i.stack = Stack(runtime: p, runtimeVersion: p, wineArch: p, translator: p, graphics: [p])
        i.settings.powerMode = p
        i.user = .init(label: p, gameSettings: p, notes: p + " C:\\users\\steamuser\\Doc")
        i.warnings = [p]
        let w = try RunBundleWriter(directory: dir, info: i)
        try w.finish { _ in }
        let json = try String(contentsOf: dir.appendingPathComponent("run.json"), encoding: .utf8)
        #expect(!json.contains("someone"))
        #expect(!json.contains("steamuser"))
        #expect(json.contains("~/x"))
    }

    @Test func hostScrubIsWholeWordAndSparesModelNames() {
        let hosts = Privacy.hostVariants(of: ["Mark-Hall.local", "Mark's MacBook Pro", "Mac", "localhost"])
        #expect(!hosts.contains("Mac") && !hosts.contains("localhost"))
        let s = Privacy.scrub("Mark-Hall wrote Market on Mac15,6 MacBook Pro as Marks-MacBook-Pro", hosts: hosts)
        #expect(s == "<host> wrote Market on Mac15,6 MacBook Pro as <host>")
        #expect(Privacy.scrub("Mac15,6", hosts: ["Mac"]) == "Mac15,6")
        #expect(Privacy.scrubPaths("D:\\Users\\Bob\\x and c:\\users\\al\\y") == "D:\\Users\\~\\x and c:\\Users\\~\\y")
    }

    @Test func localHostNamesNeedNoNetwork() {
        let t = Date()
        let names = Privacy.localHostNames()
        #expect(!names.isEmpty)
        #expect(Date().timeIntervalSince(t) < 1)
        // The Bonjour name ("Marks-MacBook-Pro") is among the scrub candidates.
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, local.count >= 4 {
            #expect(Privacy.hostVariants(of: names).contains(local))
        }
    }

    @Test func unixPathsIntoWinePrefixesAreScrubbed() {
        #expect(Privacy.scrubPaths("/Users/bob/.wine/drive_c/users/bob/AppData/x.log")
                == "~/.wine/drive_c/users/~/AppData/x.log")
        #expect(Privacy.scrubPaths("/users/bob/y") == "~/y")
        #expect(Privacy.scrubPaths("pfx/drive_c/Users/crossover/Desktop") == "pfx/drive_c/Users/~/Desktop")
        #expect(Privacy.scrubPaths("/Applications/x/usersguide") == "/Applications/x/usersguide")
        // Relative paths into a prefix (no leading slash), at the start and after a space.
        #expect(Privacy.scrubPaths("drive_c/users/bob/AppData/x.log") == "drive_c/users/~/AppData/x.log")
        #expect(Privacy.scrubPaths("saved to drive_c/Users/Bob") == "saved to drive_c/Users/~")
        #expect(Privacy.scrubPaths("xdrive_c/users/bob") == "xdrive_c/users/bob")
    }

    @Test func samplesCSVScrubsFpsApp() throws {
        let dir = tempDir().appendingPathComponent("x.mptrun")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let w = try RunBundleWriter(directory: dir, info: info())
        try w.append(sample: ["fps_app": "/Users/someone/Games/x.exe"])
        try w.finish { _ in }
        let text = try String(contentsOf: dir.appendingPathComponent("samples.csv"), encoding: .utf8)
        #expect(!text.contains("someone"))
        #expect(text.contains("~/Games/x.exe"))
    }

    @Test func emptySlugFallsBackAndDirectoriesDoNotCollide() throws {
        #expect(RunBundle.slug("™™") == "game")
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let first = RunBundle.availableDirectory(in: parent, start: d, game: "g")
        _ = try RunBundleWriter(directory: first, info: info())
        let second = RunBundle.availableDirectory(in: parent, start: d, game: "g")
        #expect(second.lastPathComponent == first.lastPathComponent.replacingOccurrences(of: ".mptrun", with: "-2.mptrun"))
    }
}
