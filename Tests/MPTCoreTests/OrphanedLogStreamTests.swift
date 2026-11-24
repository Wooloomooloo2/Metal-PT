import Foundation
import Testing
@testable import MPTCore

@Suite struct OrphanedLogStreamTests {
    private let ours = #"/usr/bin/log stream --style ndjson --predicate eventMessage BEGINSWITH "metal-HUD""#

    @Test func commandLineIsTheStreamsOwn() {
        #expect(OrphanedLogStreams.commandLine == ours)
    }

    /// Only our exact `log stream`, re-parented to launchd (ppid 1) and owned by this user.
    @Test func matchesOnlyOurOrphans() {
        let ps = """
          101     1   501 \(ours)
          102  4242   501 \(ours)
          103     1     0 \(ours)
          104     1   501 /usr/bin/log stream --predicate subsystem == "com.apple.TCC" --info
          105     1   501 \(ours) --info
          106     1   501 /usr/bin/log stream --style ndjson --predicate eventMessage BEGINSWITH "metal-HUDx"
          107     1   501 /bin/zsh -c \(ours)
        garbage line
          108     1   501 \(ours)

        """
        #expect(OrphanedLogStreams.orphans(psOutput: ps, uid: 501) == [101, 108])
        #expect(OrphanedLogStreams.orphans(psOutput: ps, uid: 0) == [103])
        #expect(OrphanedLogStreams.orphans(psOutput: "", uid: 501).isEmpty)
    }
}
