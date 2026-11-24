import Testing
import Foundation
@testable import MPTCore

@Suite struct MemoryPressureTests {
    @Test func levelMapping() {
        #expect(MemoryPressureReading.levelName(1) == "normal")
        #expect(MemoryPressureReading.levelName(2) == "warn")
        #expect(MemoryPressureReading.levelName(4) == "critical")
        #expect(MemoryPressureReading.levelName(0) == nil)
        #expect(MemoryPressureReading.levelName(3) == nil)
        #expect(MemoryPressureReading.levelName(nil) == nil)
    }

    @Test func pageoutsRateFromTwoReadings() throws {
        let rate = try #require(MemoryPressureReading.pageoutsPerSecond(from: (100, 10.0), to: (300, 12.0)))
        #expect(abs(rate - 100) < 1e-9)
        #expect(MemoryPressureReading.pageoutsPerSecond(from: (100, 10.0), to: (100, 11.0)) == 0)
        // Counter went backwards, or no time passed: unknown.
        #expect(MemoryPressureReading.pageoutsPerSecond(from: (300, 10.0), to: (100, 11.0)) == nil)
        #expect(MemoryPressureReading.pageoutsPerSecond(from: (100, 10.0), to: (200, 10.0)) == nil)
    }

    @Test func readOnThisMacGivesAKnownLevel() {
        let r = MemoryPressureReading.read()
        #expect(["normal", "warn", "critical"].contains(r.level ?? ""))
        #expect((r.swapUsedGB ?? -1) >= 0)
        #expect((r.compressedGB ?? -1) >= 0)
        #expect(r.pageouts != nil)
    }
}
