import Testing
@testable import FWCore

@Suite struct FourCCTests {
    @Test func encodesBigEndian() {
        #expect(FourCC("#KEY").rawValue == 0x234B_4559)
    }

    @Test func keepsTrailingSpace() {
        #expect(FourCC("flt ").description == "flt ")
    }

    @Test func decodesRawValue() {
        #expect(FourCC(rawValue: 0x4630_4163).description == "F0Ac")
    }

    @Test func rejectsWrongLength() {
        #expect(FourCC(string: "F0A") == nil)
        #expect(FourCC(string: "F0Acc") == nil)
    }

    @Test func rejectsNonASCII() {
        #expect(FourCC(string: "F0é") == nil)   // 4 UTF-8 bytes, but not printable ASCII
    }

    @Test func buildsFromInterpolatedString() {
        let index = 1
        #expect(FourCC(string: "F\(index)Md") == FourCC("F1Md"))
    }
}
