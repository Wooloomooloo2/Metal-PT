public enum Utilisation {
    /// Share (0...1) of residency not spent in `idleNames`; nil when nothing was resident.
    public static func busyShare(_ states: [IOReportState], idleNames: Set<String>) -> Double? {
        let shares = PowerMath.residencyShares(states)
        guard !shares.isEmpty else { return nil }
        let idle = shares.filter { idleNames.contains($0.name) }.reduce(0) { $0 + $1.share }
        return max(0, min(1, 1 - idle))
    }
}
