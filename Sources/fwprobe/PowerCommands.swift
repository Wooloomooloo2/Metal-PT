import Foundation
import FWCore

enum PowerCommands {
    static let usage = """
        fwprobe ioreport list [GROUP-PREFIX]      every IOReport channel: group / subgroup / name [unit]
        fwprobe ioreport sample [--seconds N] [--group G]...
                                                  1 s deltas for N s (default 10): watts for energy channels,
                                                  residency for performance-state channels, and sampling cost.
                                                  Default groups: Energy Model, CPU Stats, GPU Stats
        """

    static func ioreport(_ args: [String]) throws {
        let rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            let prefix = rest.first ?? ""
            let lines = Set(IOReportSampler.allChannels()
                .filter { $0.group.hasPrefix(prefix) }
                .map { "\($0.group) / \($0.subgroup) / \($0.name) [\($0.unit)]" })
            lines.sorted().forEach { print($0) }
            print("# \(lines.count) channels")
        case "sample":
            try sample(rest)
        default:
            throw ProbeError(usage)
        }
    }

    private static func sample(_ args: [String]) throws {
        let secondsText = option("--seconds", in: args) ?? "10"
        guard let seconds = Int(secondsText), seconds > 0 else {
            throw ProbeError("--seconds must be a positive integer, got '\(secondsText)'")
        }
        var groups: [String] = []
        for (index, arg) in args.enumerated() where arg == "--group" && index + 1 < args.count {
            groups.append(args[index + 1])
        }
        let sampler = try IOReportSampler(groups: groups.isEmpty ? ["Energy Model", "CPU Stats", "GPU Stats"] : groups)
        guard var previous = sampler.sample() else { throw ProbeError("IOReportCreateSamples returned nothing") }
        var previousTime = ProcessInfo.processInfo.systemUptime

        for _ in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            let start = ProcessInfo.processInfo.systemUptime
            guard let current = sampler.sample() else { continue }
            let channels = sampler.delta(from: previous, to: current)
            let cost = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let interval = start - previousTime
            previous = current
            previousTime = start

            print("── \(timestamp())  interval \(String(format: "%.3f", interval)) s  sample+delta \(String(format: "%.2f", cost)) ms")
            for channel in channels {
                switch channel.value {
                case .simple(let raw):
                    guard let joules = PowerMath.joules(raw, unit: channel.unit),
                          let watts = PowerMath.watts(joules: joules, seconds: interval),
                          watts >= 0.005 else { continue }
                    print("   \(channel.group) / \(channel.name): \(String(format: "%.3f", watts)) W")
                case .states(let states):
                    guard channel.subgroup.contains("Performance States") else { continue }
                    let shares = PowerMath.residencyShares(states).filter { $0.share >= 0.01 }
                    guard !shares.isEmpty else { continue }
                    let text = shares.map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " ")
                    print("   \(channel.subgroup) / \(channel.name): \(text)")
                case .other:
                    continue
                }
            }
        }
    }
}
