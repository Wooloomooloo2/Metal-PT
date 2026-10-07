import Foundation
import FWCore

enum BatteryCommands {
    static let usage = """
        fwprobe battery                           battery state from AppleSmartBattery
        """

    static func run(_ args: [String]) throws {
        print(try SmartBatteryReader.read().summary)
    }
}
