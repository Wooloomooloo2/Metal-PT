import Testing
import MPTCore
@testable import MPTApp

@Suite struct FrameReportingCheckTests {
    private static let selfPID: Int32 = 100
    private static let game: Int32 = 900

    /// Lookup counters and canned answers.
    private final class Lookups {
        var env: [Int32: [String: String]] = [game: ["HOME": "/Users/u"]]
        var launcher: [Int32: (name: String, pid: Int32)] = [game: (name: "Steam", pid: 500)]
        var envCalls = 0
        var launcherCalls = 0
    }

    private func check(_ l: Lookups) -> FrameReportingCheck {
        FrameReportingCheck(environment: { pid in l.envCalls += 1; return l.env[pid] },
                            launcher: { pid in l.launcherCalls += 1; return l.launcher[pid] })
    }

    private func input(_ t: Double, pid: Int32? = game, app: String? = "Cyberpunk2077", gpu: Double? = 90,
                       hud: Bool = false, logging: Bool = true, sampling: Bool = true) -> FrameReportingCheck.Input {
        FrameReportingCheck.Input(now: t, fpsLoggingOn: logging, sampling: sampling, frontmostPID: pid,
                                  frontmostApp: app, selfPID: Self.selfPID, gpuBusyPct: gpu, hudLive: hud)
    }

    /// Runs `n` ticks from `start`, each built by `make`; returns the last warning.
    @discardableResult
    private func run(_ c: inout FrameReportingCheck, from start: Int = 0, _ n: Int,
                     _ make: (Double) -> FrameReportingCheck.Input) -> String? {
        var w: String?
        for i in start..<(start + n) { w = c.tick(make(Double(i))) }
        return w
    }

    @Test func firesAfterTenBusyTicksWithLauncher() {
        let l = Lookups()
        var c = check(l)
        #expect(run(&c, 9) { input($0) } == nil)
        let w = c.tick(input(9))
        #expect(w == "Cyberpunk2077 started before FPS logging was on — quit it and Steam and open them again.")
        #expect(c.warning == w)
    }

    @Test func withoutLauncher() {
        let l = Lookups()
        l.launcher = [:]
        var c = check(l)
        #expect(run(&c, 10) { input($0) }
                == "Cyberpunk2077 started before FPS logging was on — quit it and open it again.")
    }

    @Test func neverForMetalPTItself() {
        let l = Lookups()
        l.env[Self.selfPID] = [:]
        var c = check(l)
        #expect(run(&c, 30) { input($0, pid: Self.selfPID, app: "Metal-PT") } == nil)
        #expect(l.envCalls == 0)
    }

    @Test func neverWhenTheAppHasTheVariables() {
        let l = Lookups()
        l.env[Self.game] = ["MTL_HUD_LOG_ENABLED": "1", "MTL_HUD_ENABLED": "1"]
        var c = check(l)
        #expect(run(&c, 30) { input($0) } == nil)
    }

    @Test func neverWhenFPSLoggingIsOffOrNotSampling() {
        let l = Lookups()
        var c = check(l)
        #expect(run(&c, 30) { input($0, logging: false) } == nil)
        #expect(run(&c, from: 30, 30) { input($0, sampling: false) } == nil)
        #expect(l.envCalls == 0)
    }

    @Test func neverWhenTheEnvironmentIsUnreadable() {
        let l = Lookups()
        l.env = [:]
        var c = check(l)
        #expect(run(&c, 30) { input($0) } == nil)
    }

    @Test func needsTenConsecutiveBusyTicks() {
        let l = Lookups()
        var c = check(l)
        run(&c, 9) { input($0) }
        #expect(c.tick(input(9, gpu: 49)) == nil)     // below 50 %: starts over
        #expect(run(&c, from: 10, 9) { input($0) } == nil)
        #expect(c.tick(input(19, gpu: nil)) == nil)   // unknown: starts over
        #expect(run(&c, from: 20, 10) { input($0) } != nil)
    }

    @Test func hudLinesFromTheAppPreventAndClear() {
        let l = Lookups()
        var c = check(l)
        #expect(run(&c, 30) { input($0, hud: $0 == 5) } != nil)   // one HUD tick early, then 24 quiet ticks
        var d = check(l)
        #expect(run(&d, 30) { input($0, hud: Int($0) % 9 == 0) } == nil)
        // Shown, then lines arrive: cleared.
        #expect(c.tick(input(30, hud: true)) == nil)
        #expect(c.warning == nil)
    }

    @Test func clearsWhenFrontmostChangesOrLoggingGoesOffOrAppQuits() {
        let l = Lookups()
        var c = check(l)
        run(&c, 10) { input($0) }
        #expect(c.warning != nil)
        #expect(c.tick(input(10, pid: 901, app: "Other")) == nil)

        run(&c, from: 11, 10) { input($0) }
        #expect(c.warning != nil)
        #expect(c.tick(input(21, logging: false)) == nil)

        run(&c, from: 22, 10) { input($0) }
        #expect(c.warning != nil)
        #expect(c.tick(input(32, pid: nil, app: nil)) == nil)   // quit: nothing frontmost
    }

    @Test func aGPUDipDoesNotClearAShownWarning() {
        let l = Lookups()
        var c = check(l)
        run(&c, 10) { input($0) }
        #expect(c.tick(input(10, gpu: 5)) != nil)    // paused in a menu: still not reporting
    }

    @Test func lookupsAreCachedPerPIDFor30Seconds() {
        let l = Lookups()
        l.env[Self.game] = ["MTL_HUD_LOG_ENABLED": "1"]   // keeps qualifying ticks asking
        var c = check(l)
        run(&c, 40) { input($0) }                  // qualifies from t = 9: asks at 9 and 39
        #expect(l.envCalls == 2)
        #expect(l.launcherCalls == 0)               // only asked when the warning is shown
        l.env[Self.game] = ["HOME": "/"]
        run(&c, from: 40, 25) { input($0) }         // cached until t = 69
        #expect(c.warning == nil)
        #expect(l.envCalls == 2)
        run(&c, from: 65, 5) { input($0) }
        #expect(l.envCalls == 3)
        #expect(c.warning != nil)
        run(&c, from: 70, 20) { input($0) }
        #expect(l.launcherCalls == 1)
    }

    @Test func genericNameWithoutAnAppName() {
        let l = Lookups()
        l.launcher = [:]
        var c = check(l)
        #expect(run(&c, 10) { input($0, app: nil) }?.hasPrefix("The frontmost app started before") == true)
    }
}
