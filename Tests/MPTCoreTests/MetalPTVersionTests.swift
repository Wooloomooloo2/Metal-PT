import Foundation
import Testing
import MPTCore

@Suite struct MetalPTVersionTests {
    /// `VERSION` (read by `scripts/make-app.sh` for Info.plist) and `MetalPTVersion.current` are kept equal.
    @Test func matchesVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == MetalPTVersion.current)
    }
}
