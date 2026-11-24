import Testing
import Foundation
@testable import MPTCore

@Suite struct GPUClockTests {
    /// `pmgr` `voltage-states9` on the M4 Max (hardware-baseline 2026-11-24): 16 × (Hz u32 LE, voltage u32 LE).
    static let m4MaxGPUTable: [UInt8] = hex(
        "000000007d000000807825145802000080eed5249902000000ff712fc1020000001f1337d5020000005ebe3802030000"
        + "0048f13e0203000080d54c3f2a03000080e373462a03000080e373465c0300000088334e5c030000806a074a84030000"
        + "00214152840300008027094fac030000806b9e57ac030000805e0e5e0b040000")

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// A 4-entry CPU-style table (no OFF entry) and a 20-entry table: neither fits 16 GPU states.
    static let otherTables: [[UInt8]] = [
        hex("010000009e02000001000000d502000001000000340300000100000089030000"),
        [UInt8](repeating: 1, count: 20 * 8),
    ]

    private func gpuph(_ residencies: [Int64]) -> [IOReportState] {
        residencies.enumerated().map { IOReportState(name: $0.offset == 0 ? "OFF" : "P\($0.offset)", residency: $0.element) }
    }

    @Test func picksTableMatchingStateCountWithMeasuredValues() throws {
        let table = try #require(GPUClock.table(fromPMGR: Self.otherTables + [Self.m4MaxGPUTable], stateCount: 16))
        #expect(table.count == 16)
        #expect(table[0] == 0)
        #expect(table[1] == 338)
        #expect(table[15] == 1578)
        #expect(table == [0, 338, 618, 796, 924, 952, 1056, 1062, 1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578])
    }

    @Test func noMatchingTableLeavesClockEmpty() {
        #expect(GPUClock.table(fromPMGR: Self.otherTables + [Self.m4MaxGPUTable], stateCount: 12) == nil)
        #expect(GPUClock.table(fromPMGR: [], stateCount: 16) == nil)
        // A 16-entry table without an OFF (0 Hz) first entry is not a GPU table.
        #expect(GPUClock.table(fromPMGR: [[UInt8](repeating: 1, count: 16 * 8)], stateCount: 16) == nil)
        // With no table, a sample's clock is empty and nothing crashes.
        var states = gpuph(Array(repeating: 0, count: 16))
        states[15] = IOReportState(name: "P15", residency: 100)
        #expect(GPUClock.meanMHz(states: states, table: []) == nil)
    }

    @Test func meanMHzAllOffIsNil() throws {
        let table = try #require(GPUClock.table(fromPMGR: [Self.m4MaxGPUTable], stateCount: 16))
        var r = Array(repeating: Int64(0), count: 16)
        r[0] = 1000
        #expect(GPUClock.meanMHz(states: gpuph(r), table: table) == nil)
        #expect(GPUClock.meanMHz(states: gpuph(Array(repeating: 0, count: 16)), table: table) == nil)
    }

    @Test func meanMHzIsResidencyWeightedOverActiveStates() throws {
        let table = try #require(GPUClock.table(fromPMGR: [Self.m4MaxGPUTable], stateCount: 16))
        var r = Array(repeating: Int64(0), count: 16)
        r[1] = 500; r[15] = 500
        let half = try #require(GPUClock.meanMHz(states: gpuph(r), table: table))
        #expect(abs(half - 958) < 1e-9)
        // OFF residency does not dilute the clock.
        r[0] = 9000
        let withOff = try #require(GPUClock.meanMHz(states: gpuph(r), table: table))
        #expect(abs(withOff - 958) < 1e-9)
    }

    @Test func meanMHzWithUnmappableActiveStateIsNil() {
        let states = [IOReportState(name: "OFF", residency: 10), IOReportState(name: "P20", residency: 10)]
        #expect(GPUClock.meanMHz(states: states, table: [0, 338]) == nil)
    }
}
