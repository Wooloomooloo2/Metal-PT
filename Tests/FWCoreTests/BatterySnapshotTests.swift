import Foundation
import Testing
@testable import FWCore

@Suite struct BatterySnapshotTests {
    @Test func parsesDischargingBattery() {
        // As IORegistry reports it: signed values stored as unsigned 64-bit.
        let snapshot = BatterySnapshot(properties: [
            "CurrentCapacity": 56,
            "IsCharging": false,
            "ExternalConnected": false,
            "FullyCharged": false,
            "InstantAmperage": UInt64(18_446_744_073_709_550_066),
            "Amperage": UInt64(18_446_744_073_709_550_066),
            "Voltage": 12_600,
            "Temperature": 2954,
        ])
        #expect(snapshot.percent == 56)
        #expect(snapshot.isCharging == false)
        #expect(snapshot.externalConnected == false)
        #expect(snapshot.amperageMilliamps == -1550)
        #expect(snapshot.voltageMillivolts == 12_600)
        #expect(snapshot.temperatureCelsius == 29.54)
    }

    @Test func acceptsSignedAmperage() {
        let snapshot = BatterySnapshot(properties: ["InstantAmperage": Int64(-1550)])
        #expect(snapshot.amperageMilliamps == -1550)
    }

    @Test func fallsBackToAmperage() {
        let snapshot = BatterySnapshot(properties: ["Amperage": 2100])
        #expect(snapshot.amperageMilliamps == 2100)
    }

    @Test func missingKeysAreNil() {
        let snapshot = BatterySnapshot(properties: [:])
        #expect(snapshot.percent == nil)
        #expect(snapshot.amperageMilliamps == nil)
        #expect(snapshot.temperatureCelsius == nil)
        #expect(!snapshot.summary.isEmpty)
    }
}
