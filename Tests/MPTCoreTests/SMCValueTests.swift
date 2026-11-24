import Testing
@testable import MPTCore

@Suite struct SMCValueTests {
    func value(_ type: FourCC, _ bytes: [UInt8]) -> SMCValue {
        SMCValue(key: "TEST", type: type, bytes: bytes)
    }

    @Test func floatIsLittleEndian() {
        // 42.5 = 0x422A0000
        #expect(value("flt ", [0x00, 0x00, 0x2A, 0x42]).number == 42.5)
    }

    @Test func unsignedIntegersAreLittleEndian() {
        #expect(value("ui8 ", [0x02]).number == 2)
        #expect(value("ui16", [0x02, 0x01]).number == 258)
        #expect(value("ui32", [0x2C, 0x01, 0x00, 0x00]).number == 300)
    }

    // Measured on this machine (hardware-baseline E1).
    @Test func measuredBatteryKeys() {
        #expect(SMCValue(key: "B0AC", type: "si16", bytes: [0x27, 0xFD]).number == -729)
        #expect(SMCValue(key: "B0AV", type: "ui16", bytes: [0x5E, 0x2C]).number == 11358)
        #expect(SMCValue(key: "B0CT", type: "ui16", bytes: [0x90, 0x00]).number == 144)
    }

    @Test func keyCountIsTheBigEndianException() {
        #expect(SMCValue(key: "#KEY", type: "ui32", bytes: [0x00, 0x00, 0x0D, 0x3A]).number == 3386)
    }

    @Test func signedFixedPoint() {
        // [?] sp78/fpe2 byte order not measured in E1; kept big-endian.
        #expect(value("sp78", [0x1E, 0x80]).number == 30.5)
        #expect(value("sp78", [0xFF, 0x00]).number == -1.0)
        #expect(value("fpe2", [0x1F, 0x40]).number == 2000)
    }

    @Test func signedIntegers() {
        #expect(value("si8 ", [0xFF]).number == -1)
        #expect(value("si16", [0xFE, 0xFF]).number == -2)
    }

    @Test func flag() {
        #expect(value("flag", [0x01]).number == 1)
    }

    @Test func unknownTypeHasNoNumber() {
        #expect(value("hex_", [0x01]).number == nil)
    }

    @Test func wrongByteCountHasNoNumber() {
        #expect(value("ui16", [0x01]).number == nil)
        #expect(value("flt ", [0x00, 0x00]).number == nil)
    }

    @Test func encodeFloatRoundTrips() {
        let bytes = SMCValue.encodeFloat(2500)
        #expect(bytes.count == 4)
        #expect(value("flt ", bytes).number == 2500)
    }

    @Test func hexEncodes() {
        #expect(value("ui32", [0x01, 0x00, 0x00, 0x00]).hex == "01 00 00 00")
    }

    @Test func hexDecodes() {
        #expect(Hex.decode("01000000") == [0x01, 0x00, 0x00, 0x00])
        #expect(Hex.decode("01 0a FF") == [0x01, 0x0A, 0xFF])
    }

    @Test func hexRejectsBadInput() {
        #expect(Hex.decode("") == nil)
        #expect(Hex.decode("010") == nil)
        #expect(Hex.decode("zz") == nil)
        #expect(Hex.decode("+1") == nil)
        #expect(Hex.decode("-0") == nil)
    }
}
