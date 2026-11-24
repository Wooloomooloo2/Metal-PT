import Testing
import Foundation
@testable import MPTCore

@Suite struct StackDetectorTests {
    private let protium = "/Applications/Protium.app/Contents/SharedSupport/runtime"
    private let crossOver = "/Applications/CrossOver Preview_sept_25.app/Contents/SharedSupport/CrossOver"

    @Test func protiumHZDFingerprint() {
        let s = StackDetector.fingerprint(mappedPaths: [
            "\(protium)/lib/wine/aarch64-unix/winemetal.so",
            "\(protium)/lib/wine/aarch64-unix/libarm64ecfex.so",
            "\(protium)/lib/wine/aarch64-windows/libarm64ecfex.dll",
            "\(protium)/lib/external/libvulkan_kosmickrisp.dylib",
            "\(protium)/lib/external/libvulkan.1.dylib",
            "\(protium)/lib/wine/aarch64-windows/d3d12core.dll",
            "/private/var/folders/xx/C/dxmt/HorizonZeroDawnRemastered.exe/com.apple.metal/a",
        ])
        #expect(s.runtime == "Protium")
        #expect(s.translator == "FEX")
        #expect(s.wineArch == "arm64ec")
        #expect(s.graphics == ["DXMT", "KosmicKrisp", "vkd3d"])
    }

    @Test func crossOverD3DMetal() {
        let s = StackDetector.fingerprint(mappedPaths: [
            "\(crossOver)/lib64/apple_gptk/external/D3DMetal.framework/D3DMetal",
            "/usr/libexec/rosetta/runtime",
        ])
        #expect(s.runtime == "CrossOver")
        #expect(s.translator == "Rosetta")
        #expect(s.graphics == ["D3DMetal"])
    }

    @Test func crossOverDXMTAndDXVKLayers() {
        let s = StackDetector.fingerprint(mappedPaths: [
            "\(crossOver)/lib/dxmt/x86_64-unix/winemetal.so",
            "\(crossOver)/lib/dxvk/x86_64-windows/d3d11.dll",
            "\(crossOver)/lib64/libMoltenVK.dylib",
            "\(crossOver)/lib/wine/x86_64-windows/libvkd3d-1.dll",
        ])
        #expect(s.graphics == ["DXMT", "DXVK", "MoltenVK", "vkd3d"])
    }

    @Test func crossOverWinemetalDllAloneIsNotDXMT() {
        let s = StackDetector.fingerprint(mappedPaths: [
            "\(crossOver)/lib/wine/x86_64-windows/winemetal.dll",
        ])
        #expect(!s.graphics.contains("DXMT"))
        #expect(s.runtime == "CrossOver")
    }

    @Test func nativeWhenNothingMatches() {
        let s = StackDetector.fingerprint(mappedPaths: ["/usr/lib/libSystem.B.dylib"])
        #expect(s.runtime == "native")
        #expect(s.translator == nil)
        #expect(s.graphics.isEmpty)
    }

    @Test func kegworksRuntime() {
        let wrapper = StackDetector.fingerprint(mappedPaths: [
            "/Users/x/Applications/Kegworks/Game.app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so",
        ])
        #expect(wrapper.runtime == "Kegworks")
        let app = StackDetector.fingerprint(mappedPaths: ["/Applications/Kegworks.app/Contents/MacOS/Kegworks"])
        #expect(app.runtime == "Kegworks")
    }

    @Test func gptkRuntime() {
        #expect(StackDetector.fingerprint(mappedPaths: [
            "/usr/local/opt/game-porting-toolkit/lib/wine/x86_64-unix/ntdll.so",
        ]).runtime == "GPTK")
        #expect(StackDetector.fingerprint(mappedPaths: [
            "/Volumes/Game Porting Toolkit-2.1/redist/lib/external/D3DMetal.framework/D3DMetal",
        ]).runtime == "GPTK")
    }

    @Test func unknownWineIsNotNative() {
        #expect(StackDetector.fingerprint(mappedPaths: ["/opt/wine-stable/lib/wine/x86_64-unix/ntdll.so"]).runtime
                == "Wine (unknown)")
        #expect(StackDetector.fingerprint(mappedPaths: ["/opt/homebrew/bin/wine64"]).runtime == "Wine (unknown)")
        #expect(StackDetector.fingerprint(mappedPaths: ["/opt/w/bin/wineserver"]).runtime == "Wine (unknown)")
        #expect(StackDetector.fingerprint(mappedPaths: ["/opt/w/bin/wine64-preloader"]).runtime == "Wine (unknown)")
        // A named runtime wins over the generic Wine match.
        #expect(StackDetector.fingerprint(mappedPaths: ["\(protium)/lib/wine/aarch64-unix/ntdll.so"]).runtime
                == "Protium")
        #expect(StackDetector.fingerprint(mappedPaths: ["/Users/x/winery/notes.txt"]).runtime == "native")
    }

    @Test func appBundleExtraction() {
        #expect(StackDetector.appBundlePath(in: [
            "/usr/lib/x", "\(crossOver)/lib/a.dylib",
        ]) == "/Applications/CrossOver Preview_sept_25.app")
        #expect(StackDetector.appBundlePath(in: ["\(protium)/lib/a"]) == "/Applications/Protium.app")
        #expect(StackDetector.appBundlePath(in: ["/usr/lib/x"]) == nil)
    }

    @Test func exeNameFromWindowsPath() {
        #expect(ProcessNames.exeName(fromArgv0:
            "Z:\\Volumes\\OWC Express 1M2\\Protium Library\\steamapps\\common\\HZD\\HorizonZeroDawnRemastered.exe")
            == "HorizonZeroDawnRemastered.exe")
        #expect(ProcessNames.exeName(fromArgv0: "/usr/bin/yes") == "yes")
    }

    @Test func detectOnOwnProcessIsNative() {
        let s = StackDetector.detect(pid: getpid())
        #expect(s.runtime == "native")
    }

    @Test func detectOnBogusPidIsUnknown() {
        #expect(StackDetector.detect(pid: 999_999).runtime == nil)
    }

    @Test func oahRuntimeMeansRosetta() {
        let s = StackDetector.fingerprint(mappedPaths: ["/System/Library/Frameworks/oah/liboah.dylib"])
        #expect(s.translator == "Rosetta")
    }

    @Test func dxmtMetalCacheAloneMeansDXMT() {
        let s = StackDetector.fingerprint(mappedPaths: [
            "/private/var/folders/xx/C/dxmt/Game.exe/com.apple.metal/a"])
        #expect(s.graphics.contains("DXMT"))
    }

    @Test func procArgsParsing() {
        #expect(ProcessNames.argv0(fromProcArgs: []) == nil)
        #expect(ProcessNames.argv0(fromProcArgs: [2, 0, 0, 0, 0x2f, 0x61]) == nil)   // exec path never ends
        var b: [UInt8] = [2, 0, 0, 0]
        b += Array("/usr/bin/yes".utf8) + [0, 0, 0]
        b += Array("Z:\\g\\a.exe".utf8) + [0] + Array("-x".utf8) + [0]
        #expect(ProcessNames.argv0(fromProcArgs: b) == "Z:\\g\\a.exe")
    }

    @Test func displayNameOfOwnProcess() {
        #expect(ProcessNames.displayName(pid: getpid()) != nil)
    }
}
