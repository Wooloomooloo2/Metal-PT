import Foundation
import MPTCore

enum FanCommands {
    static let usage = """
        mptprobe fan-test --rpm N [--seconds S] [--unlock]
                                                  (sudo) force every fan to N RPM for S s (default 30), log RPM
                                                  every 2 s, then hand the fans back. --unlock writes Ftst=1 first
        mptprobe fan-release                       (sudo) hand every fan back to macOS, unconditionally
        """

    static func fanTest(_ args: [String]) throws {
        try requireRoot()
        guard let rpmText = option("--rpm", in: args) else { throw ProbeError(usage) }
        guard let rpm = Float(rpmText), rpm.isFinite, rpm > 0 else { throw ProbeError("--rpm must be a positive number, got '\(rpmText)'") }
        let secondsText = option("--seconds", in: args) ?? "30"
        guard let seconds = Int(secondsText), seconds > 0 else { throw ProbeError("--seconds must be a positive integer, got '\(secondsText)'") }
        let unlock = args.contains("--unlock")

        let smc = try SMCConnection()
        let fanCount = Int(try smc.read("FNum").number ?? 0)
        guard fanCount > 0 else { throw ProbeError("FNum reports no fans") }
        for fan in 0..<fanCount {
            let minimum = try smc.read(fanKey(fan, "Mn")).number ?? .nan
            let maximum = try smc.read(fanKey(fan, "Mx")).number ?? .nan
            print("fan \(fan): min \(minimum)  max \(maximum)  now \(describe(smc, fan, "Ac"))  mode \(describe(smc, fan, "Md"))")
            guard Double(rpm) >= minimum, Double(rpm) <= maximum else {
                throw ProbeError("\(rpm) RPM is outside fan \(fan)'s range \(minimum)–\(maximum)")
            }
        }

        // Originals, read before anything is written. Any that cannot be read fall back (with a warning) to a safe value.
        let originalModes: [[UInt8]] = (0..<fanCount).map { original(smc, fanKey($0, "Md"), fallback: [0]) }
        let originalTargets: [[UInt8]] = (0..<fanCount).map { original(smc, fanKey($0, "Tg"), fallback: [0, 0, 0, 0]) }
        let ftst: FourCC = "Ftst"
        let originalFtst: [UInt8]? = unlock ? original(smc, ftst, fallback: [0]) : nil

        // Restore order: each Md, each Tg, then Ftst. Hints spell out the exact original bytes.
        var steps: [(key: FourCC, bytes: [UInt8], label: String)] = []
        for fan in 0..<fanCount { steps.append((fanKey(fan, "Md"), originalModes[fan], "fan \(fan) restore Md")) }
        for fan in 0..<fanCount { steps.append((fanKey(fan, "Tg"), originalTargets[fan], "fan \(fan) restore Tg")) }
        if let originalFtst { steps.append((ftst, originalFtst, "restore Ftst")) }
        let undoCommands = steps.map { "sudo mptprobe smc write \($0.key) \(Hex.encode($0.bytes).replacingOccurrences(of: " ", with: ""))" }.joined(separator: "; ")
        let hint = "Run: \(undoCommands)  (or: sudo mptprobe fan-release)"
        let plannedSteps = steps

        let restoreFailed = Counter()
        let lease = Lease {
            guard let restoreSMC = try? SMCConnection() else {
                restoreFailed.increment()
                try? FileHandle.standardError.write(contentsOf: Data("RESTORE FAILED: cannot open the SMC. \(hint)\n".utf8))
                return
            }
            // Every write first; reporting (which can block on a stuck stdout) only afterwards.
            var report: [(ok: Bool, text: String)] = []
            for step in plannedSteps {
                do {
                    try restoreSMC.write(step.key, bytes: step.bytes)
                    report.append((true, "\(timestamp())  \(step.label): \(step.key) = \(Hex.encode(step.bytes))"))
                } catch {
                    restoreFailed.increment()
                    report.append((false, "RESTORE FAILED for \(step.label) (\(step.key)): \(error). \(hint)"))
                }
            }
            for line in report {
                if line.ok { print(line.text) } else { try? FileHandle.standardError.write(contentsOf: Data((line.text + "\n").utf8)) }
            }
        }
        lease.releaseOnSignals()

        var failure: Error?
        do {
            if unlock {
                try lease.perform { try smc.write(ftst, bytes: [1]) }
                print("\(timestamp())  wrote Ftst=01")
                Thread.sleep(forTimeInterval: 1)
            }
            for fan in 0..<fanCount {
                try lease.perform {
                    try smc.write(fanKey(fan, "Md"), bytes: [1])
                    try smc.write(fanKey(fan, "Tg"), bytes: SMCValue.encodeFloat(rpm))
                }
                print("\(timestamp())  fan \(fan): wrote Md=01, Tg=\(rpm)")
            }
            for elapsed in stride(from: 0, through: seconds, by: 2) {
                let fans = (0..<fanCount).map { fan in
                    "fan\(fan) Md \(describe(smc, fan, "Md")) Tg \(describe(smc, fan, "Tg")) Ac \(describe(smc, fan, "Ac"))"
                }
                print("\(timestamp())  t=\(elapsed)s  " + fans.joined(separator: "  |  "))
                if elapsed < seconds { Thread.sleep(forTimeInterval: 2) }
            }
        } catch {
            failure = error
        }
        lease.release()
        if restoreFailed.value > 0 { throw ProbeError("fan restore failed; see RESTORE FAILED lines above. \(hint)") }
        if let failure { throw failure }
    }

    /// Reads a key's current bytes; on failure warns on stderr and returns `fallback`.
    private static func original(_ smc: SMCConnection, _ key: FourCC, fallback: [UInt8]) -> [UInt8] {
        if let bytes = try? smc.read(key).bytes { return bytes }
        try? FileHandle.standardError.write(contentsOf: Data("WARNING: cannot read original \(key); restore will write fallback \(Hex.encode(fallback))\n".utf8))
        return fallback
    }

    /// Writes `bytes` to `key` and reports the outcome; failures go to stderr. Returns success.
    private static func writeAndReport(_ smc: SMCConnection, _ key: FourCC, _ bytes: [UInt8], label: String, failure: String) -> Bool {
        do {
            try smc.write(key, bytes: bytes)
            print("\(timestamp())  \(label): \(key) = \(Hex.encode(bytes))")
            return true
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(failure) for \(label) (\(key)): \(error)\n".utf8))
            return false
        }
    }

    /// Hands every fan back to macOS with 00, even if we think we never took them (hard rule 2).
    /// Prints each fan's Md before and after. Returns the number of failed writes.
    @discardableResult
    static func releaseFans(fanCount: Int) -> Int {
        guard let smc = try? SMCConnection() else {
            try? FileHandle.standardError.write(contentsOf: Data("RELEASE FAILED: cannot open the SMC. Run: sudo mptprobe fan-release\n".utf8))
            return 1
        }
        var failures = 0
        for fan in 0..<fanCount {
            print("\(timestamp())  fan \(fan): Md before release \(describe(smc, fan, "Md"))")
            if !writeAndReport(smc, fanKey(fan, "Md"), [0], label: "fan \(fan) release Md", failure: "RELEASE FAILED") { failures += 1 }
            print("\(timestamp())  fan \(fan): Md after release \(describe(smc, fan, "Md"))")
        }
        if (try? smc.keyInfo("Ftst")) != nil,
           !writeAndReport(smc, "Ftst", [0], label: "release Ftst", failure: "RELEASE FAILED") { failures += 1 }
        return failures
    }

    static func fanRelease() throws {
        try requireRoot()
        let fanCount = (try? SMCConnection().read("FNum").number).map { Int($0) } ?? 2
        if releaseFans(fanCount: max(fanCount, 1)) > 0 { throw ProbeError("fan release had failures; see RELEASE FAILED lines above") }
    }

    private static func fanKey(_ fan: Int, _ suffix: String) -> FourCC {
        FourCC(string: "F\(fan)\(suffix)")!
    }

    private static func describe(_ smc: SMCConnection, _ fan: Int, _ suffix: String) -> String {
        guard let value = try? smc.read(fanKey(fan, suffix)) else { return "?" }
        return value.number.map { String(format: "%.0f", $0) } ?? value.hex
    }
}
