import Foundation
import Testing
@testable import MPTCore

/// `KERN_PROCARGS2` bytes: argc (Int32, host order), exec path, NUL padding, argv, env.
private func procArgs(exec: String, argv: [String], env: [String], pad: Int = 3, trailingZeros: Int = 8) -> [UInt8] {
    var argc = Int32(argv.count)
    var b = withUnsafeBytes(of: &argc) { Array($0) }
    b += Array(exec.utf8) + [UInt8](repeating: 0, count: pad)
    for s in argv + env { b += Array(s.utf8) + [0] }
    b += [UInt8](repeating: 0, count: trailingZeros)
    return b
}

@Suite struct ProcessEnvironmentTests {
    @Test func parsesArgvAndEnvironment() throws {
        let b = procArgs(exec: "/Applications/G.app/Contents/MacOS/G", argv: ["/Applications/G.app/Contents/MacOS/G", "-x"],
                         env: ["HOME=/Users/u", "MTL_HUD_LOG_ENABLED=1", "EMPTY=", "A=b=c"])
        let p = try #require(ProcessNames.parseProcArgs(b))
        #expect(p.argv == ["/Applications/G.app/Contents/MacOS/G", "-x"])
        #expect(p.env == ["HOME": "/Users/u", "MTL_HUD_LOG_ENABLED": "1", "EMPTY": "", "A": "b=c"])
    }

    @Test func noEnvironmentIsEmptyNotNil() throws {
        let p = try #require(ProcessNames.parseProcArgs(procArgs(exec: "/bin/x", argv: ["x"], env: [])))
        #expect(p.argv == ["x"])
        #expect(p.env.isEmpty)
    }

    @Test func noPaddingAndNoTrailingZeros() throws {
        let p = try #require(ProcessNames.parseProcArgs(
            procArgs(exec: "/bin/x", argv: ["x"], env: ["K=V"], pad: 1, trailingZeros: 0)))
        #expect(p.env == ["K": "V"])
    }

    @Test func truncatedBuffers() {
        #expect(ProcessNames.parseProcArgs([]) == nil)
        #expect(ProcessNames.parseProcArgs([1, 0, 0]) == nil)                          // short argc
        #expect(ProcessNames.parseProcArgs([1, 0, 0, 0, 0x2f, 0x61]) == nil)           // exec path never ends
        #expect(ProcessNames.parseProcArgs([2, 0, 0, 0, 0x2f, 0, 0x61, 0]) == nil)     // argc 2, one arg
        // Env cut mid-string: the complete strings are kept, the partial one is dropped.
        var b = procArgs(exec: "/x", argv: ["x"], env: ["A=1"], trailingZeros: 0)
        b += Array("B=tru".utf8)
        let p = ProcessNames.parseProcArgs(b)
        #expect(p?.env == ["A": "1"])
    }

    @Test func argcLargerThanTheStringsIsNil() {
        var b = procArgs(exec: "/x", argv: ["x"], env: ["K=V"], trailingZeros: 0)
        b.replaceSubrange(0..<4, with: [3, 0, 0, 0])      // argc 3, two strings follow
        #expect(ProcessNames.parseProcArgs(b) == nil)
        b.replaceSubrange(0..<4, with: [0xff, 0xff, 0xff, 0x7f])   // Int32.max
        #expect(ProcessNames.parseProcArgs(b) == nil)
        b.replaceSubrange(0..<4, with: [0xff, 0xff, 0xff, 0xff])   // negative
        #expect(ProcessNames.parseProcArgs(b) == nil)
    }

    /// An empty argv[0] cannot be told apart from the NUL padding after the exec path (ps(1) has the same limit):
    /// it is absorbed, so argv takes the next string and env starts one string later. Documented, not detected.
    @Test func emptyArgv0IsAbsorbedByThePadding() throws {
        let p = try #require(ProcessNames.parseProcArgs(procArgs(exec: "/x", argv: [""], env: ["A=1", "B=2"])))
        #expect(p.argv == ["A=1"])
        #expect(p.env == ["B": "2"])
    }

    @Test func ignoresStringsWithoutEquals() throws {
        let p = try #require(ProcessNames.parseProcArgs(procArgs(exec: "/x", argv: ["x"], env: ["junk", "K=V"])))
        #expect(p.env == ["K": "V"])
    }

    @Test func readsOwnEnvironment() throws {
        let env = try #require(ProcessNames.environment(pid: getpid()))
        #expect(env["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    }
}

@Suite struct ProcessTreeTests {
    private static let steam = "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
    private static let game = "/Users/u/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/"
        + "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"

    private func tree(_ t: [Int32: (Int32, String)]) -> (Int32) -> (ppid: Int32, path: String)? {
        { pid in t[pid].map { (ppid: $0.0, path: $0.1) } }
    }

    @Test func steamIsTheLauncher() {
        let t = tree([900: (500, Self.game), 500: (1, Self.steam), 1: (0, "/sbin/launchd")])
        let l = ProcessTree.launcher(of: 900, info: t)
        #expect(l?.name == "Steam")
        #expect(l?.pid == 500)
    }

    @Test func dotAppBundleNameDropsExtension() {
        let t = tree([900: (600, Self.game), 600: (500, "/bin/sh"),
                      500: (1, "/Applications/Heroic.app/Contents/MacOS/Heroic")])
        #expect(ProcessTree.launcher(of: 900, info: t)?.name == "Heroic")
    }

    @Test func helperInsideALauncherNamesTheOuterApp() {
        let helper = "/Applications/Steam.app/Contents/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper"
        let t = tree([900: (700, Self.game), 700: (1, helper)])
        #expect(ProcessTree.launcher(of: 900, info: t)?.name == "Steam")
    }

    @Test func skipsAncestorsInsideTheGamesOwnApp() {
        let child = "/Games/G.app/Contents/MacOS/G"
        let parent = "/Games/G.app/Contents/MacOS/launcher"
        let t = tree([900: (800, child), 800: (500, parent), 500: (1, Self.steam)])
        #expect(ProcessTree.launcher(of: 900, info: t)?.name == "Steam")
    }

    @Test func launchedByLaunchdHasNoLauncher() {
        let t = tree([900: (1, Self.game), 1: (0, "/sbin/launchd")])
        #expect(ProcessTree.launcher(of: 900, info: t) == nil)
    }

    @Test func nonAppAncestorsOnlyHasNoLauncher() {
        let t = tree([900: (600, Self.game), 600: (1, "/bin/zsh")])
        #expect(ProcessTree.launcher(of: 900, info: t) == nil)
    }

    @Test func unreadableOrCyclicChainStops() {
        #expect(ProcessTree.launcher(of: 900, info: tree([:])) == nil)
        #expect(ProcessTree.launcher(of: 900, info: tree([900: (600, Self.game)])) == nil)   // parent unreadable
        #expect(ProcessTree.launcher(of: 900, info: tree([900: (600, Self.game), 600: (900, "/bin/sh")])) == nil)
    }

    @Test func bundleUsesTheLastContentsMacOS() {
        // An ordinary folder named Contents above the app is not a bundle.
        #expect(ProcessTree.bundle(ofExecutable: "/Users/u/Contents/Games/G.app/Contents/MacOS/G")?.name == "G")
        #expect(ProcessTree.bundle(ofExecutable: "/Users/u/Contents/MacOS/Games/G.app/Contents/MacOS/G")?.path
                == "/Users/u/Contents/MacOS/Games/G.app")
        // A helper inside an app's Frameworks belongs to the outer app (Steam's real layout).
        let helper = "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/Frameworks/"
            + "Steam Helper.app/Contents/MacOS/Steam Helper"
        #expect(ProcessTree.bundle(ofExecutable: helper)?.path
                == "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam")
        #expect(ProcessTree.bundle(ofExecutable: "/A.app/Contents/Helpers/B.app/Contents/MacOS/b")?.name == "A")
        // Measured on this Mac: Steam's helpers live under Contents/MacOS/Frameworks.
        let measured = "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Frameworks/"
            + "Steam Helper.app/Contents/MacOS/Steam Helper"
        #expect(ProcessTree.bundle(ofExecutable: measured)?.name == "Steam")
    }

    @Test func bundleOf() {
        #expect(ProcessTree.bundle(ofExecutable: Self.steam)?.name == "Steam")
        #expect(ProcessTree.bundle(ofExecutable: Self.game)?.name == "Cyberpunk2077")
        #expect(ProcessTree.bundle(ofExecutable: "/bin/zsh") == nil)
    }

    @Test func readsOwnParent() {
        // The test runner's own chain is readable (the result depends on how tests were started).
        #expect(ProcessTree.info(pid: getpid())?.ppid == getppid())
    }
}
