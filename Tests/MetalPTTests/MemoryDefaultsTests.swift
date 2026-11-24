import Foundation
import Testing
@testable import MetalPT

/// `MemoryDefaults` keeps everything in memory, so tests and snapshots leave no plist in ~/Library/Preferences.
@Suite struct MemoryDefaultsTests {
    @Test func accessorsReadWhatWasWritten() {
        let d = MemoryDefaults()
        d.set([1, 2], forKey: "a")
        d.set(Data([1, 2, 3]), forKey: "data")
        d.set(URL(fileURLWithPath: "/tmp/x"), forKey: "url")
        d.set(1, forKey: "int")
        d.set(0.5, forKey: "double")
        d.set(["x", "y"], forKey: "strings")
        #expect(d.array(forKey: "a")?.count == 2)
        #expect(d.data(forKey: "data") == Data([1, 2, 3]))
        #expect(d.url(forKey: "url")?.path == "/tmp/x")
        #expect(d.bool(forKey: "int"))
        #expect(d.integer(forKey: "int") == 1)
        #expect(d.double(forKey: "double") == 0.5)
        #expect(d.float(forKey: "double") == 0.5)
        #expect(d.stringArray(forKey: "strings") == ["x", "y"])
        d.removeObject(forKey: "int")
        #expect(d.object(forKey: "int") == nil)
        #expect(!d.bool(forKey: "int"))
    }

    @Test func registeredDefaultsAreAFallback() {
        let d = MemoryDefaults()
        d.register(defaults: ["opacity": 0.6, "style": "auto"])
        #expect(d.double(forKey: "opacity") == 0.6)
        d.set(0.3, forKey: "opacity")
        #expect(d.double(forKey: "opacity") == 0.3)
        d.removeObject(forKey: "opacity")
        #expect(d.double(forKey: "opacity") == 0.6)
        #expect(d.string(forKey: "style") == "auto")
        #expect(d.dictionaryRepresentation()["style"] as? String == "auto")
    }

    @Test func instancesAreIndependentAndNothingIsPersisted() {
        let a = MemoryDefaults(), b = MemoryDefaults()
        a.set("x", forKey: "k")
        #expect(b.string(forKey: "k") == nil)
        #expect(UserDefaults(suiteName: "metal-pt.memory")?.string(forKey: "k") == nil)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/metal-pt.memory.plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }
}
