/// Raw bytes of one SMC key plus a best-effort numeric reading.
///
/// Measured on this machine (hardware-baseline E1): `ui16`/`ui32`/`ui64`/`si16` and `flt ` are little-endian, except
/// the key `#KEY`, which is big-endian. `sp78`/`fpe2` are big-endian but not measured `[?]`.
public struct SMCValue: Equatable, Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    public var number: Double? {
        switch type.description {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: littleEndian(bytes))))
        case "ui8 ", "flag":
            guard bytes.count == 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(integer(bytes))
        case "ui32":
            guard bytes.count == 4 else { return nil }
            return Double(integer(bytes))
        case "ui64":
            guard bytes.count == 8 else { return nil }
            return Double(integer(bytes))
        case "si8 ":
            guard bytes.count == 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(integer(bytes))))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bigEndian(bytes)))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(bigEndian(bytes)) / 4
        default:
            return nil
        }
    }

    /// Little-endian, except the one measured big-endian key `#KEY`.
    private func integer(_ bytes: [UInt8]) -> UInt64 {
        key == "#KEY" ? bigEndian(bytes) : littleEndian(bytes)
    }

    public var hex: String { Hex.encode(bytes) }

    /// Bytes for writing a `flt ` key (e.g. a fan target RPM).
    public static func encodeFloat(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
}

private func bigEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
}

private func littleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
}
