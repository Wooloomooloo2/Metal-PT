import Foundation
import FWCore

enum SMCCommands {
    static let usage = """
        fwprobe smc list [PREFIX]                 every key (or keys starting with PREFIX): type, size, bytes, value
        fwprobe smc read KEY...                   read keys
        fwprobe smc watch [--interval S] KEY...   print keys and battery state every S seconds (default 5)
        """

    static func run(_ args: [String]) throws {
        let smc = try SMCConnection()
        let rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            try list(smc, prefix: rest.first)
        case "read":
            guard !rest.isEmpty else { throw ProbeError(usage) }
            for name in rest { print(describe(smc, try smcKey(name))) }
        default:
            throw ProbeError(usage)
        }
    }

    static func smcKey(_ text: String) throws -> FourCC {
        guard let key = FourCC(string: text) else { throw ProbeError("not a four-character SMC key: '\(text)'") }
        return key
    }

    static func line(_ value: SMCValue) -> String {
        let number = value.number.map { "  = \($0)" } ?? ""
        return "\(value.key)  [\(value.type)] \(value.bytes.count)B  \(value.hex)\(number)"
    }

    static func describe(_ smc: SMCConnection, _ key: FourCC) -> String {
        do { return line(try smc.read(key)) } catch { return "\(key)  <\(error)>" }
    }

    private static func list(_ smc: SMCConnection, prefix: String?) throws {
        let count = try smc.keyCount()
        print("# \(count) keys")
        for index in 0..<count {
            let key = try smc.key(at: index)
            if let prefix, !key.description.hasPrefix(prefix) { continue }
            print(describe(smc, key))
        }
    }
}
