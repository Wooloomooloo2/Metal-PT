/// A four-character code such as an SMC key (`F0Ac`) or SMC data type (`flt `), packed big-endian.
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// nil unless `string` is exactly four printable ASCII characters.
    public init?(string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(stringLiteral value: String) {
        guard let code = FourCC(string: value) else { preconditionFailure("not a four-character code: \(value)") }
        self = code
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
