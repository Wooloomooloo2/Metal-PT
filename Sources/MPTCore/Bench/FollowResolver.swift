/// The `.preferTranslated` follow rule as a pure function, shared by `RunRecorder` (recordings) and the app's
/// telemetry hub (following outside a recording), so both pick the same process.
public enum FollowResolver {
    /// Among `pids` minus `exclude`: a live `pinned` PID wins; else the busiest live one whose stack is known and not
    /// "native"; else the busiest live one; else (nothing live) the one with the most frames so far.
    /// "Live" is relative to `now` (`FrameCounter.staleAfter`). `stack` must not block.
    public static func preferTranslated(counter: FrameCounter, pids: some Collection<Int32>, exclude: Set<Int32>,
                                        pinned: Int32?, at now: Double, stack: (Int32) -> Stack?) -> Int32? {
        if let pinned, !exclude.contains(pinned), counter.isLive(pid: pinned, at: now) { return pinned }
        let candidates = pids.filter { !exclude.contains($0) }
        let live = candidates.filter { counter.isLive(pid: $0, at: now) }
        let translated = live.filter { pid in
            guard let runtime = stack(pid)?.runtime else { return false }
            return runtime != "native"
        }
        if let best = counter.busiestLive(at: now, among: translated) { return best }
        if let best = counter.busiestLive(at: now, among: live) { return best }
        // Nothing live: the most frames so far among the non-excluded.
        return candidates.max { a, b in
            let (fa, fb) = (counter.totalFrames(pid: a), counter.totalFrames(pid: b))
            return fa != fb ? fa < fb : a > b
        }
    }

    /// The live PIDs of `pids` minus `exclude`, busiest (most frames) first; ties: lower PID first.
    public static func liveCandidates(counter: FrameCounter, pids: some Collection<Int32>, exclude: Set<Int32>,
                                      at now: Double) -> [Int32] {
        pids.filter { !exclude.contains($0) && counter.isLive(pid: $0, at: now) }.sorted { a, b in
            let (fa, fb) = (counter.totalFrames(pid: a), counter.totalFrames(pid: b))
            return fa != fb ? fa > fb : a < b
        }
    }
}
