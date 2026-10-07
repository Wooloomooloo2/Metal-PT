import CMacPrivate
import Foundation

public enum IOReportError: Error {
    case noChannels
    case subscriptionFailed
}

public struct IOReportChannel: Sendable {
    public enum Value: Sendable {
        case simple(Int64)
        case states([IOReportState])
        case other(UInt8)
    }

    public let group: String
    public let subgroup: String
    public let name: String
    public let unit: String
    public let value: Value
}

/// A subscription to IOReport channel groups (e.g. "Energy Model", "CPU Stats", "GPU Stats").
/// Unprivileged. Take two samples and diff them: energy channels give joules over the interval,
/// state channels give residency over the interval.
public final class IOReportSampler {
    private let subscription: IOReportSubscription
    private let subscribed: CFMutableDictionary

    public init(groups: [String]) throws {
        var merged: CFMutableDictionary?
        for group in groups {
            guard let channels = IOReportCopyChannelsInGroup(group as CFString, nil, 0, 0, 0) else { continue }
            if let merged {
                IOReportMergeChannels(merged, channels, nil)
            } else {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
            }
        }
        guard let merged else { throw IOReportError.noChannels }
        var subscribedOut: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, merged, &subscribedOut, 0, nil),
              let subscribedOut else { throw IOReportError.subscriptionFailed }
        self.subscription = subscription
        self.subscribed = subscribedOut.takeRetainedValue()
    }

    public func sample() -> CFDictionary? {
        IOReportCreateSamples(subscription, subscribed, nil)
    }

    public func delta(from previous: CFDictionary, to current: CFDictionary) -> [IOReportChannel] {
        guard let delta = IOReportCreateSamplesDelta(previous, current, nil) else { return [] }
        return Self.channels(in: delta, readValues: true)
    }

    /// Every channel the system publishes, names only.
    public static func allChannels() -> [IOReportChannel] {
        guard let all = IOReportCopyAllChannels(0, 0) else { return [] }
        return channels(in: all, readValues: false)
    }

    static func channels(in dictionary: CFDictionary, readValues: Bool) -> [IOReportChannel] {
        guard let items = (dictionary as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        return items.map { item in
            let channel = item as CFDictionary
            let format = IOReportChannelGetFormat(channel)
            var value = IOReportChannel.Value.other(format)
            if readValues {
                switch format {
                case 1:
                    value = .simple(IOReportSimpleGetIntegerValue(channel, 0))
                case 2:
                    let count = IOReportStateGetCount(channel)
                    value = .states((0..<max(count, 0)).map { index in
                        IOReportState(
                            name: (IOReportStateGetNameForIndex(channel, index) as String?) ?? "?",
                            residency: IOReportStateGetResidency(channel, index)
                        )
                    })
                default:
                    break
                }
            }
            return IOReportChannel(
                group: (IOReportChannelGetGroup(channel) as String?) ?? "",
                subgroup: (IOReportChannelGetSubGroup(channel) as String?) ?? "",
                name: (IOReportChannelGetChannelName(channel) as String?) ?? "",
                unit: (IOReportChannelGetUnitLabel(channel) as String?) ?? "",
                value: value
            )
        }
    }
}
