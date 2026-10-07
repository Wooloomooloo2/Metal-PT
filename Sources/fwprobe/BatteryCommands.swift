import Foundation
import FWCore

enum BatteryCommands {
    static let usage = """
        fwprobe battery                           battery state from AppleSmartBattery
        fwprobe charge-test KEY HEX [--seconds N] (sudo) write HEX to KEY, log battery current every 5 s for N s
                                                  (default 120), then restore the original bytes
        """

    static func run(_ args: [String]) throws {
        print(try SmartBatteryReader.read().summary)
    }

    /// Writes `hex` to `key`, logs battery state, restores the original bytes on exit, error or signal.
    static func chargeTest(_ args: [String]) throws {
        try requireRoot()
        let values = positional(args)
        guard values.count == 2, let inhibit = Hex.decode(values[1]) else { throw ProbeError(usage) }
        let key = try SMCCommands.smcKey(values[0])
        let seconds = Int(option("--seconds", in: args) ?? "120") ?? 120

        let smc = try SMCConnection()
        let original = try smc.read(key).bytes
        print("\(timestamp())  before: \(SMCCommands.line(try smc.read(key)))")
        print("\(timestamp())  battery: \(try SmartBatteryReader.read().summary)")

        let lease = Lease {
            do {
                try SMCConnection().write(key, bytes: original)
                print("\(timestamp())  restored \(key) = \(Hex.encode(original))")
            } catch {
                let undo = Hex.encode(original).replacingOccurrences(of: " ", with: "")
                print("RESTORE FAILED for \(key): \(error). Run: sudo fwprobe smc write \(key) \(undo)")
            }
        }
        lease.releaseOnSignals()
        defer { lease.release() }

        try smc.write(key, bytes: inhibit)
        print("\(timestamp())  wrote \(Hex.encode(inhibit)); read-back: \(SMCCommands.line(try smc.read(key)))")
        for elapsed in stride(from: 0, through: seconds, by: 5) {
            let value = SMCCommands.describe(smc, key)
            print("\(timestamp())  t=\(elapsed)s  \(try SmartBatteryReader.read().summary)  |  \(value)")
            if elapsed < seconds { Thread.sleep(forTimeInterval: 5) }
        }
    }
}
