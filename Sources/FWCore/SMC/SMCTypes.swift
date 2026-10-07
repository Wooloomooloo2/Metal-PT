public enum SMCError: Error, Equatable {
    case serviceNotFound
    case openFailed(Int32)
    case callFailed(Int32)
    case notPrivileged
    case keyNotFound(FourCC)
    case smcResult(UInt8)
    case sizeMismatch(key: FourCC, expected: Int, got: Int)
}

public struct SMCKeyInfo: Equatable, Sendable {
    public let size: Int
    public let type: FourCC

    public init(size: Int, type: FourCC) {
        self.size = size
        self.type = type
    }

    /// Refuses a write whose length does not match the key's declared size.
    public func checkWrite(key: FourCC, bytes: [UInt8]) throws {
        guard bytes.count == size else {
            throw SMCError.sizeMismatch(key: key, expected: size, got: bytes.count)
        }
    }
}
