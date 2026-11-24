import Testing
@testable import MPTCore

@Suite struct SMCKeyInfoTests {
    @Test func acceptsMatchingSize() throws {
        try SMCKeyInfo(size: 4, type: "ui32").checkWrite(key: "CHTE", bytes: [1, 0, 0, 0])
    }

    @Test func refusesSizeMismatch() {
        #expect(throws: SMCError.sizeMismatch(key: "CHTE", expected: 1, got: 4)) {
            try SMCKeyInfo(size: 1, type: "ui8 ").checkWrite(key: "CHTE", bytes: [1, 0, 0, 0])
        }
    }
}
