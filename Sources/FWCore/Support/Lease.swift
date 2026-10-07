import Foundation

/// Something borrowed from the hardware (a charge key, the fans) with a guaranteed hand-back.
/// `restore` runs exactly once: on `release()`, or on SIGINT/SIGTERM/SIGHUP after `releaseOnSignals()`.
/// SIGKILL cannot be caught; recovery from that is the next start's job (spec §2, fan lease).
public final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let restore: @Sendable () -> Void
    private var signalSources: [DispatchSourceSignal] = []

    public init(restore: @escaping @Sendable () -> Void) {
        self.restore = restore
    }

    public func releaseOnSignals() {
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
