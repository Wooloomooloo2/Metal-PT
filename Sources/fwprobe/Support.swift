import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Value following `name` (e.g. `--seconds 60`), or nil.
func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// Arguments that are neither `--flags` nor the value of a `--flag value` pair.
/// Flags that take no value (`--unlock`) must not be followed by a positional.
func positional(_ args: [String]) -> [String] {
    var result: [String] = []
    var skipNext = false
    for (index, arg) in args.enumerated() {
        if skipNext { skipNext = false; continue }
        if arg.hasPrefix("--") {
            let next = index + 1 < args.count ? args[index + 1] : nil
            skipNext = next.map { !$0.hasPrefix("--") && Double($0) != nil } ?? false
            continue
        }
        result.append(arg)
    }
    return result
}

func requireRoot() throws {
    guard getuid() == 0 else { throw ProbeError("this command writes the SMC: run it with sudo") }
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}
