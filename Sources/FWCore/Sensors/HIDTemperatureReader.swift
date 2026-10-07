import CMacPrivate
import Foundation
import IOKit.hidsystem

public struct TemperatureReading: Sendable {
    public let name: String
    public let celsius: Double
}

/// Temperature sensors published through the HID event system (unprivileged).
public enum HIDTemperatureReader {
    public static func read() -> [TemperatureReading] {
        let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) else { return [] }
        var readings: [TemperatureReading] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
            guard intProperty(service, "PrimaryUsagePage") == Int(kCHIDSensorUsagePage),
                  intProperty(service, "PrimaryUsage") == Int(kCHIDTemperatureSensorUsage),
                  let event = IOHIDServiceClientCopyEvent(service, kCHIDEventTypeTemperature, 0, 0) else { continue }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "?"
            readings.append(TemperatureReading(name: name, celsius: IOHIDEventGetFloatValue(event, kCHIDTemperatureLevelField)))
        }
        return readings.sorted { $0.name < $1.name }
    }

    private static func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }
}
