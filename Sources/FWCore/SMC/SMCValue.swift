/// Raw bytes of one SMC key plus a best-effort numeric reading.
///
/// Integer and fixed-point types are big-endian; `flt ` is little-endian on Apple Silicon.
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
            return Double(bigEndian(bytes))
        case "ui32":
            guard bytes.count == 4 else { return nil }
            return Double(bigEndian(bytes))
        case "ui64":
            guard bytes.count == 8 else { return nil }
            return Double(bigEndian(bytes))
        case "si8 ":
            guard bytes.count == 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bigEndian(bytes))))
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
