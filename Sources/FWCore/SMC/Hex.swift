import Foundation

public enum Hex {
    /// `[0x01, 0x00]` → `"01 00"`.
    public static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Accepts `"0100"` or `"01 00"`; nil if empty, odd-length or not hex.
    public static func decode(_ text: String) -> [UInt8]? {
        let digits = Array(text.filter { !$0.isWhitespace })
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
