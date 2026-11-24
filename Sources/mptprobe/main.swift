import Foundation
import MPTCore

// Line-buffer stdout so logs survive kill/Ctrl-C when piped to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    mptprobe — M0 hardware probe for Metal-PT. Write commands need sudo.

    \(SMCCommands.usage)
    \(BatteryCommands.usage)
    \(FanCommands.usage)
    \(PowerCommands.usage)
    """

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "smc":
        try SMCCommands.run(Array(args.dropFirst()))
    case "battery":
        try BatteryCommands.run(Array(args.dropFirst()))
    case "charge-test":
        try BatteryCommands.chargeTest(Array(args.dropFirst()))
    case "fan-test":
        try FanCommands.fanTest(Array(args.dropFirst()))
    case "fan-release":
        try FanCommands.fanRelease()
    case "ioreport":
        try PowerCommands.ioreport(Array(args.dropFirst()))
    case "temps":
        try PowerCommands.temps(Array(args.dropFirst()))
    default:
        print(usage)
        exit(args.isEmpty ? 0 : 64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
