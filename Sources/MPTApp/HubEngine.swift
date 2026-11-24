import Foundation
import MPTCore

/// The hub's sources and follow state. Everything under `lock`, except the sampler, which is used under
/// `samplerLock` (one thread at a time). Sources are started/stopped outside `lock`.
final class HubEngine: @unchecked Sendable {
    struct Update: Sendable {
        var snapshot: HubSnapshot
        var addToHistory: Bool
        var expiredPin: Int32?
        var recording: SessionStatus?
        var recordingID: UUID?
        /// Assigned under the engine lock, increasing: the hub drops an update older than one it applied.
        var seq: UInt64 = 0
    }

    private struct Follow: Equatable {
        var pid: Int32?
        var app: String?
        var stack: Stack?
    }

    /// Margin past `FrameCounter.staleAfter` for the quiet check.
    static let quietMargin = 0.1

    let stackCache: AsyncStackCache
    private let deps: TelemetryHub.Dependencies
    private let lock = NSLock()
    /// Serialises sampler creation and use (a `TelemetrySampler` is used from one thread at a time).
    private let samplerLock = NSLock()
    /// Creates and primes the sampler off the main thread.
    private let samplerQueue = DispatchQueue(label: "mpt.hub.sampler", qos: .utility)

    // Under `lock`.
    private var sink: (@Sendable (Update) -> Void)?
    private var sampler: TelemetrySource?
    private var samplerWanted = false
    private var seq: UInt64 = 0
    private var stream: HUDEventSource?
    private var generation = 0
    private var tickTimer: HubTimer?
    private var quietTimer: HubTimer?
    private var counter = FrameCounter()
    private var imagePaths: [Int32: String] = [:]
    private var names: [Int32: String] = [:]
    private var pinned: Int32?
    private var subscribers: [UUID: @Sendable (HUDEvent) -> Void] = [:]
    private var lastSample: TelemetrySample?
    private var lastFollow = Follow()

    init(deps: TelemetryHub.Dependencies) {
        self.deps = deps
        stackCache = AsyncStackCache(now: deps.clock, detect: deps.detectStack)
    }

    func setSink(_ sink: @escaping @Sendable (Update) -> Void) { lock.withLock { self.sink = sink } }

    func setPinned(_ pid: Int32?) { lock.withLock { pinned = pid } }

    /// Starts (a fresh source each time: a stopped `MetalHUDLogStream` cannot restart) or stops the log stream.
    /// Stopping forgets the follow state and publishes a follow-only snapshot (no followed game), which also
    /// supersedes any update made before the stop that is still on its way to the main thread.
    func setStream(_ on: Bool) throws {
        if on {
            let started: (HUDEventSource, Int)? = lock.withLock {
                guard stream == nil else { return nil }
                let s = deps.makeStream()
                stream = s
                generation += 1
                return (s, generation)
            }
            guard let (s, gen) = started else { return }
            do {
                try s.start { [weak self] event in self?.hud(event, generation: gen) }
            } catch {
                lock.withLock { if generation == gen { stream = nil } }
                throw error
            }
        } else {
            let (old, update): (HUDEventSource?, Update?) = lock.withLock {
                guard let old = stream else { return (nil, nil) }
                stream = nil
                generation += 1
                counter = FrameCounter()
                imagePaths = [:]
                quietTimer?.cancel()
                quietTimer = nil
                lastFollow = Follow()
                return (old, stamped(Update(snapshot: snapshot(lastSample ?? TelemetrySample(), Follow(), fps: nil),
                                            addToHistory: false)))
            }
            old?.stop()
            if let update { deliver(update) }
        }
    }

    /// `active`: the sampler is wanted (created and primed off main, on `samplerQueue` or by the first
    /// `sampleNow`, whichever comes first; dropped at once otherwise). `ticking`: the hub's own 1 Hz timer runs it.
    func setSampling(active: Bool, ticking: Bool) {
        let create: Bool = lock.withLock {
            samplerWanted = active
            if !active { sampler = nil }
            if ticking && active {
                if tickTimer == nil {
                    tickTimer = deps.scheduler.repeating(every: TelemetryHub.tickInterval) { [weak self] in
                        self?.tick()
                    }
                    quietTimer?.cancel()
                    quietTimer = nil
                }
            } else {
                tickTimer?.cancel()
                tickTimer = nil
            }
            return active && sampler == nil
        }
        if create {
            samplerQueue.async { [weak self] in
                guard let self else { return }
                samplerLock.withLock { _ = ensureSampler() }
            }
        }
    }

    /// Waits for sampler work queued so far (tests).
    func waitForSamplerWork() { samplerQueue.sync {} }

    /// Under `samplerLock`: the sampler, created and primed (its first sample has no power or utilisation) if
    /// wanted and missing.
    private func ensureSampler() -> TelemetrySource? {
        if let s = lock.withLock({ sampler }) { return s }
        guard lock.withLock({ samplerWanted }) else { return nil }
        let s = deps.makeSampler()
        _ = s.sample()
        return lock.withLock {
            guard samplerWanted else { return nil }
            if sampler == nil { sampler = s }
            return sampler
        }
    }

    func shutdown() {
        let old: HUDEventSource? = lock.withLock {
            tickTimer?.cancel()
            quietTimer?.cancel()
            tickTimer = nil
            quietTimer = nil
            sampler = nil
            samplerWanted = false
            generation += 1
            defer { stream = nil }
            return stream
        }
        old?.stop()
    }

    /// One sample from the hub's sampler (also the recording's `TelemetrySource`); nil when there is no sampler.
    func sampleNow() -> TelemetrySample? {
        samplerLock.withLock {
            guard let sampler = ensureSampler() else { return nil }
            let s = sampler.sample()
            lock.withLock { lastSample = s }
            return s
        }
    }

    func recordingTick(_ status: SessionStatus, id: UUID) {
        publish(sample: status.sample, recording: status, id: id)
    }

    func subscribe(_ id: UUID, _ handler: @escaping @Sendable (HUDEvent) -> Void) {
        lock.withLock { subscribers[id] = handler }
    }

    func unsubscribe(_ id: UUID) { _ = lock.withLock { subscribers.removeValue(forKey: id) } }

    /// False only when the stream should be running and has died (no FPS logging is not a failure).
    var streamHealthy: Bool {
        guard let s = lock.withLock({ stream }) else { return true }
        return s.isRunning
    }

    func candidates() -> [(pid: Int32, app: String, stack: Stack?)] {
        lock.withLock {
            FollowResolver.liveCandidates(counter: counter, pids: imagePaths.keys, exclude: [deps.selfPID],
                                          at: deps.clock())
                .map { (pid: $0, app: name(of: $0) ?? "pid \($0)", stack: stackCache.stack(for: $0)) }
        }
    }

    // MARK: Private

    private func tick() {
        guard let s = sampleNow() else { return }
        publish(sample: s, recording: nil, id: nil)
    }

    private func publish(sample: TelemetrySample, recording: SessionStatus?, id: UUID?) {
        let update: Update = lock.withLock {
            let (follow, fps, expired) = resolve()
            lastFollow = follow
            return stamped(Update(snapshot: snapshot(sample, follow, fps: fps), addToHistory: true,
                                  expiredPin: expired, recording: recording, recordingID: id))
        }
        deliver(update)
    }

    private func hud(_ event: HUDEvent, generation gen: Int) {
        let (subs, update): ([@Sendable (HUDEvent) -> Void], Update?) = lock.withLock {
            guard gen == generation else { return ([], nil) }
            counter.add(event)
            imagePaths[event.pid] = event.imagePath
            return (Array(subscribers.values), followOnlyUpdate(gen))
        }
        for s in subs { s(event) }
        if let update { deliver(update) }
    }

    /// The quiet check: no line for `staleAfter` since the last one.
    private func quiet(generation gen: Int) {
        let update: Update? = lock.withLock {
            guard gen == generation else { return nil }
            quietTimer = nil
            return followOnlyUpdate(gen)
        }
        if let update { deliver(update) }
    }

    /// Under `lock`. Without a sampler nothing ticks: publish a change of followed game (or an expired pin) as it
    /// happens, and re-check after `staleAfter` while a game is followed, so a game that quits is noticed.
    private func followOnlyUpdate(_ gen: Int) -> Update? {
        guard sampler == nil else { return nil }
        let (follow, fps, expired) = resolve()
        quietTimer?.cancel()
        quietTimer = nil
        if follow.pid != nil {
            quietTimer = deps.scheduler.once(after: FrameCounter.staleAfter + Self.quietMargin) { [weak self] in
                self?.quiet(generation: gen)
            }
        }
        guard follow != lastFollow || expired != nil else { return nil }
        lastFollow = follow
        return stamped(Update(snapshot: snapshot(lastSample ?? TelemetrySample(), follow, fps: fps),
                              addToHistory: false, expiredPin: expired))
    }

    /// Under `lock`: the live followed process now, and a pin that is no longer live (cleared here).
    private func resolve() -> (Follow, Double?, Int32?) {
        let now = deps.clock()
        let exclude: Set<Int32> = [deps.selfPID]
        var expired: Int32?
        if let p = pinned, exclude.contains(p) || !counter.isLive(pid: p, at: now) {
            expired = p
            pinned = nil
        }
        let cache = stackCache
        guard let pid = FollowResolver.preferTranslated(counter: counter, pids: imagePaths.keys, exclude: exclude,
                                                        pinned: pinned, at: now, stack: { cache.stack(for: $0) }),
              counter.isLive(pid: pid, at: now) else { return (Follow(), nil, expired) }
        return (Follow(pid: pid, app: name(of: pid), stack: cache.stack(for: pid)), counter.fps(pid: pid, at: now),
                expired)
    }

    /// Under `lock`.
    private func stamped(_ u: Update) -> Update {
        seq += 1
        var u = u
        u.seq = seq
        return u
    }

    private func snapshot(_ sample: TelemetrySample, _ follow: Follow, fps: Double?) -> HubSnapshot {
        HubSnapshot(time: deps.clock(), sample: sample, fps: fps, followedPID: follow.pid, followedApp: follow.app,
                    stack: follow.stack)
    }

    /// Under `lock`. Exe name from argv[0] (Wine reports the Windows exe there), else the HUD image path; cached.
    private func name(of pid: Int32) -> String? {
        if let cached = names[pid] { return cached }
        let found = deps.argv0(pid).map(ProcessNames.exeName(fromArgv0:))
            ?? imagePaths[pid].map(ProcessNames.exeName(fromArgv0:))
        if let found, !found.isEmpty { names[pid] = found; return found }
        return nil
    }

    private func deliver(_ update: Update) {
        lock.withLock { sink }?(update)
    }
}
