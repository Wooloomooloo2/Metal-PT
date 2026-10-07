import Foundation
import IOKit

public enum BatteryReadError: Error {
    case serviceNotFound
    case readFailed(Int32)
}

public enum SmartBatteryReader {
    public static func read() throws -> BatterySnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw BatteryReadError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            throw BatteryReadError.readFailed(result)
        }
        return BatterySnapshot(properties: dictionary)
    }
}
