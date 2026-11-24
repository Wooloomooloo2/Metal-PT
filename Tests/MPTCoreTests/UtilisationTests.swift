import Testing
@testable import MPTCore

@Suite struct UtilisationTests {
    @Test func busyShareIgnoresIdleAndDown() {
        let states = [
            IOReportState(name: "IDLE", residency: 300),
            IOReportState(name: "DOWN", residency: 100),
            IOReportState(name: "V6P0", residency: 600),
        ]
        let busy = Utilisation.busyShare(states, idleNames: ["IDLE", "DOWN"])
        #expect(busy != nil && abs(busy! - 0.6) < 1e-9)
    }

    @Test func busyShareZeroTotalIsNil() {
        let states = [IOReportState(name: "IDLE", residency: 0), IOReportState(name: "V6P0", residency: 0)]
        #expect(Utilisation.busyShare(states, idleNames: ["IDLE"]) == nil)
        #expect(Utilisation.busyShare([], idleNames: ["IDLE"]) == nil)
    }

    @Test func gpuBusyFromOff() {
        let states = [IOReportState(name: "OFF", residency: 900), IOReportState(name: "P1", residency: 100)]
        let busy = Utilisation.busyShare(states, idleNames: ["OFF"])
        #expect(busy != nil && abs(busy! - 0.1) < 1e-9)
    }

    private func core(_ name: String, idle: Int64, busy: Int64) -> IOReportChannel {
        IOReportChannel(group: "CPU Stats", subgroup: "CPU Core Performance States", name: name, unit: "24Mticks",
                        value: .states([IOReportState(name: "IDLE", residency: idle),
                                        IOReportState(name: "V1P1", residency: busy)]))
    }

    @Test func aggregateSplitsClustersAndTakesMax() {
        let a = Utilisation.aggregate([
            core("PCPU000", idle: 50, busy: 50), core("PCPU010", idle: 90, busy: 10),
            core("ECPU000", idle: 20, busy: 80),
            IOReportChannel(group: "GPU Stats", subgroup: "GPU Performance States", name: "GPUPH", unit: "",
                            value: .states([IOReportState(name: "OFF", residency: 75),
                                            IOReportState(name: "P1", residency: 25)])),
        ])
        #expect(abs(a.pUtil! - 30) < 1e-9)
        #expect(abs(a.eUtil! - 80) < 1e-9)
        #expect(abs(a.coreMax! - 80) < 1e-9)
        #expect(abs(a.gpuBusy! - 25) < 1e-9)
    }

    @Test func aggregateSkipsZeroTotalAndMissingCores() {
        let a = Utilisation.aggregate([core("PCPU000", idle: 0, busy: 0), core("PCPU010", idle: 75, busy: 25)])
        #expect(abs(a.pUtil! - 25) < 1e-9)
        #expect(a.eUtil == nil)
        #expect(abs(a.coreMax! - 25) < 1e-9)
        #expect(a.gpuBusy == nil)
        #expect(Utilisation.aggregate([]).pUtil == nil)
    }
}
