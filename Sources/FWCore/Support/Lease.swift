import Foundation

/// Something borrowed from the hardware (a charge key, the fans) with a guaranteed hand-back.
/// `restore` runs exactly once: on `release()`, or on SIGINT/SIGTERM/SIGHUP after `releaseOnSignals()`.
/// SIGKILL cannot be caught; recovery from that is the next start's job (spec §2, fan lease).
///
/// `restore` and `perform` bodies both run while holding the lease lock, so a signal can never restore
/// in the middle of a guarded write, and a slow restore delays signal exit by design.
public enum LeaseError: Error { case released }

public final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let restore: @Sendable () -> Void
    private var signalSources: [DispatchSourceSignal] = []

    public init(restore: @escaping @Sendable () -> Void) {
        self.restore = restore
    }

    public func releaseOnSignals() {
        // A dead pipe (e.g. `| tee` killed by Ctrl-C) must not kill us before restore runs.
        signal(SIGPIPE, SIG_IGN)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                release()
                exit(128 + signalNumber)
            }
            source.resume()
            lock.withLock { signalSources.append(source) }
        }
    }

    /// Runs `body` under the lease lock; throws `LeaseError.released` (without running it) if already released.
    public func perform(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { throw LeaseError.released }
        try body()
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        restore()
    }

    public var isReleased: Bool {
        lock.withLock { released }
    }
}
