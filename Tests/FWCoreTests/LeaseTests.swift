import Foundation
import Testing
@testable import FWCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct LeaseTests {
    @Test func restoresExactlyOnce() {
        let counter = Counter()
        let lease = Lease { counter.increment() }
        #expect(!lease.isReleased)
        lease.release()
        lease.release()
        #expect(counter.value == 1)
        #expect(lease.isReleased)
    }

    @Test func restoresExactlyOnceAcrossThreads() {
        let counter = Counter()
        let lease = Lease { counter.increment() }
        DispatchQueue.concurrentPerform(iterations: 200) { _ in lease.release() }
        #expect(counter.value == 1)
    }

    @Test func doesNotRestoreUntilReleased() {
        let counter = Counter()
        _ = Lease { counter.increment() }
        #expect(counter.value == 0)
    }
}
