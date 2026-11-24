import Testing
@testable import FWCore

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
}
