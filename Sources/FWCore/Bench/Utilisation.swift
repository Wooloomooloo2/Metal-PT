public enum Utilisation {
    /// Share (0...1) of residency not spent in `idleNames`; nil when nothing was resident.
    public static func busyShare(_ states: [IOReportState], idleNames: Set<String>) -> Double? {
        let shares = PowerMath.residencyShares(states)
        guard !shares.isEmpty else { return nil }
        let idle = shares.filter { idleNames.contains($0.name) }.reduce(0) { $0 + $1.share }
        return max(0, min(1, 1 - idle))
    }
}

extension Utilisation {
    /// CPU and GPU utilisation (percent) from one interval's IOReport channels.
    /// Cluster utilisation is the mean over the cores present with non-zero residency; `coreMax` spans both clusters.
    static func aggregate(_ channels: [IOReportChannel])
        -> (pUtil: Double?, eUtil: Double?, coreMax: Double?, gpuBusy: Double?) {
        var p: [Double] = [], e: [Double] = []
        for channel in channels where channel.subgroup == "CPU Core Performance States" {
            guard case .states(let states) = channel.value,
                  let busy = busyShare(states, idleNames: ["IDLE", "DOWN"]) else { continue }
            if channel.name.hasPrefix("PCPU") { p.append(busy * 100) }
            else if channel.name.hasPrefix("ECPU") { e.append(busy * 100) }
        }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        var gpuBusy: Double?
        if let gpu = channels.first(where: { $0.subgroup == "GPU Performance States" && $0.name == "GPUPH" }),
           case .states(let states) = gpu.value,
           let busy = busyShare(states, idleNames: ["OFF"]) {
            gpuBusy = busy * 100
        }
        return (mean(p), mean(e), (p + e).max(), gpuBusy)
    }
}
