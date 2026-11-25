import Testing
import Foundation
@testable import MPTCore

@Suite struct StoreAppIDTests {
    @Test func steamAppIdWins() {
        #expect(StoreAppID.steam(from: ["SteamAppId": "1245620", "SteamGameId": "99"]) == "steam:1245620")
    }

    @Test func fallsBackToGameId() {
        #expect(StoreAppID.steam(from: ["SteamGameId": "570"]) == "steam:570")
    }

    @Test func invalidAppIdFallsBackToValidGameId() {
        #expect(StoreAppID.steam(from: ["SteamAppId": "abc", "SteamGameId": "570"]) == "steam:570")
    }

    @Test func rejectsInvalidValues() {
        for bad in ["", "0", "00", "abc", "12a", "-5", " 12", "12 ", "12345678901", "１２３", "1.5", "steam:5"] {
            #expect(StoreAppID.steam(from: ["SteamAppId": bad]) == nil, "\(bad)")
        }
        #expect(StoreAppID.steam(from: [:]) == nil)
        #expect(StoreAppID.steam(from: ["Other": "5"]) == nil)
    }

    @Test func acceptsTenDigits() {
        #expect(StoreAppID.steam(from: ["SteamAppId": "1234567890"]) == "steam:1234567890")
    }

    @Test func recorderSetsStoreAppIDFromGameEnvironment() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: IdleTelemetry(), startTime: 0, follow: .busiest,
                            argv0: { _ in "/x/Game" }, environment: { pid in pid == 9 ? ["SteamAppId": "570"] : nil })
        r.hud(event(pid: 9, frames: 0, at: 0))
        r.hud(event(pid: 9, frames: 60, at: 1))
        try r.tick(at: 1.2)
        try r.finish(at: 2)
        #expect(try RunBundle.load(dir).info.game.storeAppID == "steam:570")
    }

    @Test func recorderKeepsExistingStoreAppIDAndLeavesNilWithoutEnv() throws {
        let (w, dir) = try makeWriter(storeAppID: "gog:1")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: IdleTelemetry(), startTime: 0, follow: .busiest,
                            argv0: { _ in "/x/Game" }, environment: { _ in ["SteamAppId": "570"] })
        r.hud(event(pid: 9, frames: 0, at: 0))
        try r.finish(at: 2)
        #expect(try RunBundle.load(dir).info.game.storeAppID == "gog:1")

        let (w2, dir2) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir2.deletingLastPathComponent()) }
        let r2 = RunRecorder(writer: w2, telemetry: IdleTelemetry(), startTime: 0, follow: .busiest,
                             argv0: { _ in "/x/Game" }, environment: { _ in nil })
        r2.hud(event(pid: 9, frames: 0, at: 0))
        try r2.finish(at: 2)
        #expect(try RunBundle.load(dir2).info.game.storeAppID == nil)
    }

    private final class IdleTelemetry: TelemetrySource, @unchecked Sendable {
        func sample() -> TelemetrySample { TelemetrySample(gpuW: 1, smcPower: [:], fanRPM: [], batteryPct: 80, onAC: true) }
    }

    private func makeWriter(storeAppID: String? = nil) throws -> (RunBundleWriter, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwsid-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("x.mptrun")
        let info = RunInfo(appVersion: "test", machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max",
                                                               memoryGB: 64, osVersion: "26.0", osBuild: "x"),
                           game: .init(exe: "run", storeAppID: storeAppID), start: Date(timeIntervalSince1970: 0))
        return (try RunBundleWriter(directory: dir, info: info), dir)
    }

    private func event(pid: Int32, frames: Int, at t: Double) -> HUDEvent {
        HUDEvent(pid: pid, imagePath: "/x/Game", time: t, line: MetalHUDLine(frames: frames, a: 0, b: 0, frameTimes: []))
    }
}
