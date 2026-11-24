import CMacPrivate
import Foundation
import IOKit.hidsystem

public struct TemperatureReading: Sendable {
    public let name: String
    public let celsius: Double
}

/// Temperature sensors published through the HID event system (unprivileged). One-shot: creates a client per call.
public enum HIDTemperatureReader {
    public static func read() -> [TemperatureReading] {
        HIDTemperatureSource().read()
    }
}

/// Keeps one HID event-system client and the list of temperature services for its lifetime, so repeated reads
/// (the 1 Hz benchmark recorder) only fetch events. Use from one thread at a time.
public final class HIDTemperatureSource {
    private let client: IOHIDEventSystemClient?
    private let sensors: [(service: IOHIDServiceClient, name: String)]

    public init() {
        // Used instead of the public IOHIDEventSystemClientCreateSimpleClient: on M4 Max / macOS 26.6 the simple client returns services whose CopyEvent is always nil.
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        var found: [(IOHIDServiceClient, String)] = []
        if let client, let services = IOHIDEventSystemClientCopyServices(client) {
            for index in 0..<CFArrayGetCount(services) {
                guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
                let service = Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
                guard Self.intProperty(service, "PrimaryUsagePage") == Int(kCHIDSensorUsagePage),
                      Self.intProperty(service, "PrimaryUsage") == Int(kCHIDTemperatureSensorUsage) else { continue }
                let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "?"
                found.append((service, name))   // the array element is retained by `found`
            }
        }
        sensors = found.sorted { $0.1 < $1.1 }
    }

    public func read() -> [TemperatureReading] {
        sensors.compactMap { sensor in
            guard let event = IOHIDServiceClientCopyEvent(sensor.service, kCHIDEventTypeTemperature, 0, 0) else { return nil }
            return TemperatureReading(name: sensor.name, celsius: IOHIDEventGetFloatValue(event, kCHIDTemperatureLevelField))
        }
    }

    private static func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }
}
