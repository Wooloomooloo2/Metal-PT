import Testing
@testable import FWCore

@Suite struct PowerMathTests {
    @Test func convertsEnergyUnits() {
        #expect(PowerMath.joules(1500, unit: "mJ") == 1.5)
        #expect(PowerMath.joules(2_000_000, unit: "uJ") == 2.0)
        #expect(PowerMath.joules(3_000_000_000, unit: "nJ") == 3.0)
        #expect(PowerMath.joules(5, unit: " mJ ") == 0.005)
    }

    @Test func unknownUnitIsNil() {
        #expect(PowerMath.joules(1, unit: "W") == nil)
        #expect(PowerMath.joules(1, unit: "") == nil)
    }

    @Test func wattsNeedAPositiveInterval() {
        #expect(PowerMath.watts(joules: 10, seconds: 2) == 5)
        #expect(PowerMath.watts(joules: 10, seconds: 0) == nil)
        #expect(PowerMath.watts(joules: 10, seconds: -1) == nil)
    }

    @Test func residencySharesSumToOne() {
        let shares = PowerMath.residencyShares([
            IOReportState(name: "IDLE", residency: 300),
            IOReportState(name: "P1", residency: 100),
        ])
        #expect(shares.map(\.name) == ["IDLE", "P1"])
        #expect(shares.map(\.share) == [0.75, 0.25])
    }

    @Test func zeroResidencyGivesNoShares() {
        #expect(PowerMath.residencyShares([IOReportState(name: "IDLE", residency: 0)]).isEmpty)
        #expect(PowerMath.residencyShares([]).isEmpty)
    }

    @Test func negativeResidencyCountsAsZero() {
        let shares = PowerMath.residencyShares([
            IOReportState(name: "A", residency: -5),
            IOReportState(name: "B", residency: 10),
        ])
        #expect(shares.map(\.share) == [0, 1])
    }
}
