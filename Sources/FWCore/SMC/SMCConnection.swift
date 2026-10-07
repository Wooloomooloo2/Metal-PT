import CMacPrivate
import IOKit

/// A connection to the AppleSMC user client. Reads work unprivileged; writes need root.
/// Not thread-safe: use one connection per thread.
public final class SMCConnection {
    private var connection: io_connect_t = 0

    public init() throws {
        let result = csmc_open(&connection)
        if result == kCSMCNotFound { throw SMCError.serviceNotFound }
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    deinit {
        IOServiceClose(connection)
    }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        var input = CSMCParam()
        input.key = key.rawValue
        input.data8 = kCSMCCmdReadKeyInfo
        let output = try call(&input, key: key)
        return SMCKeyInfo(size: Int(output.keyInfo.dataSize), type: FourCC(rawValue: output.keyInfo.dataType))
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = CSMCParam()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = kCSMCCmdReadBytes
        let output = try call(&input, key: key)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCValue(key: key, type: info.type, bytes: bytes)
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        try info.checkWrite(key: key, bytes: bytes)
        // CSMCParam's data buffer is 32 bytes; refuse rather than overflow it.
        guard bytes.count <= 32 else { throw SMCError.sizeMismatch(key: key, expected: 32, got: bytes.count) }
        var input = CSMCParam()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = kCSMCCmdWriteBytes
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        _ = try call(&input, key: key)
    }

    public func keyCount() throws -> Int {
        Int(try read("#KEY").number ?? 0)
    }

    public func key(at index: Int) throws -> FourCC {
        var input = CSMCParam()
        input.data8 = kCSMCCmdReadIndex
        input.data32 = UInt32(index)
        return FourCC(rawValue: try call(&input, key: nil).key)
    }

    private func call(_ input: inout CSMCParam, key: FourCC?) throws -> CSMCParam {
        var output = CSMCParam()
        let result = csmc_call(connection, &input, &output)
        if result == kCSMCNotPrivileged { throw SMCError.notPrivileged }
        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
        switch output.result {
        case 0: return output
        case 0x84: throw key.map { SMCError.keyNotFound($0) } ?? SMCError.smcResult(0x84)
        default: throw SMCError.smcResult(output.result)
        }
    }
}
