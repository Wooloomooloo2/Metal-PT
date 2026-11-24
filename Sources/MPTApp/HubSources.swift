import Foundation
import MPTCore

// The recording's views of the hub's sources (`TelemetryHub.startRecording` builds the session from them).

/// A recording's telemetry: a sample from the hub's one sampler (taken on the session's tick).
final class HubTelemetrySource: TelemetrySource, @unchecked Sendable {
    private let engine: HubEngine
    init(engine: HubEngine) { self.engine = engine }
    func sample() -> TelemetrySample { engine.sampleNow() ?? TelemetrySample() }
}

/// A recording's HUD events: a fan-out subscription to the hub's stream. `start`/`stop` subscribe/unsubscribe and
/// never start or stop the stream itself; no stream (FPS logging off) means no events, not a failure.
final class SharedHUDSource: HUDEventSource, @unchecked Sendable {
    private let engine: HubEngine
    private let id = UUID()
    private let lock = NSLock()
    private var stopped = false

    init(engine: HubEngine) { self.engine = engine }

    func start(onEvent: @escaping @Sendable (HUDEvent) -> Void) throws {
        lock.withLock {
            guard !stopped else { return }
            engine.subscribe(id, onEvent)
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            engine.unsubscribe(id)
        }
    }

    var isRunning: Bool { engine.streamHealthy }
}
