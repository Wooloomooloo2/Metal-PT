import Foundation
import MPTCore

extension TelemetryHub.Dependencies {
    /// Sources that do nothing: no sampler readings, no log stream, timers that never fire, no recordings.
    /// For a hub that only shows fixture data (`showFixture`, snapshots and previews).
    public static var inert: Self {
        .init(makeSampler: { InertSampler() }, makeStream: { InertStream() }, clock: { Date().timeIntervalSince1970 },
              scheduler: InertScheduler(), argv0: { _ in nil }, detectStack: { _ in Stack() }, selfPID: getpid(),
              makeSession: { _, _ in throw CocoaError(.featureUnsupported) })
    }
}

private final class InertSampler: TelemetrySource {
    func sample() -> TelemetrySample { TelemetrySample() }
}

private final class InertStream: HUDEventSource {
    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {}
    func stop() {}
}

private struct InertTimer: HubTimer {
    func cancel() {}
}

private struct InertScheduler: HubScheduler {
    func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { InertTimer() }
    func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { InertTimer() }
}
