import Foundation
import MPTCore

/// `mpt payload`: the four upload parts the app sends to metal-pt.com, written as files (golden fixtures for the site).
enum PayloadCommands {
    static let usage = """
        payload RUN --out DIR [--notes] [--runs DIR] [--test-key-hex HEX --timestamp TS]
                                       write bundle.zip, run.json, samples.csv and summary.json (the publish payload;
                                       the last three are byte-identical to the copies in the zip) into DIR;
                                       notes are left out unless --notes; with --test-key-hex (a 32-byte P-256
                                       private key, 64 hex digits, for golden fixtures only) and --timestamp also
                                       writes headers.json { key, timestamp, signature } (base64url, signed over
                                       the publish message of spec 4.B)
        """

    static func run(_ args: [String]) throws {
        var notes = false, out: String?, runs: String?, run: String?, keyHex: String?, timestamp: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--notes": notes = true
            case "--out", "--runs", "--test-key-hex", "--timestamp":
                guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
                switch a {
                case "--out": out = args[i + 1]
                case "--runs": runs = args[i + 1]
                case "--test-key-hex": keyHex = args[i + 1]
                default: timestamp = args[i + 1]
                }
                i += 1
            default:
                guard !a.hasPrefix("--") else { throw UsageError("unexpected argument '\(a)'") }
                guard run == nil else { throw UsageError("payload takes one run, got '\(a)' too") }
                run = a
            }
            i += 1
        }
        guard let run else { throw UsageError("payload needs a run") }
        guard let out else { throw UsageError("payload needs --out DIR") }
        guard (keyHex == nil) == (timestamp == nil) else {
            throw UsageError("--test-key-hex and --timestamp go together")
        }
        let bundle = try RunBundle.load(try RecordCommands.locateRun(run, out: runs), frames: true)
        let payload = try PublishPayload.make(bundle, includeNotes: notes)
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.bundleZip.write(to: dir.appendingPathComponent("bundle.zip"))
        try payload.runJSON.write(to: dir.appendingPathComponent("run.json"))
        try payload.samplesCSV.write(to: dir.appendingPathComponent("samples.csv"))
        try payload.summaryJSON.write(to: dir.appendingPathComponent("summary.json"))
        if let keyHex, let timestamp {
            guard keyHex.count == 64, let raw = Data(hexString: keyHex) else {
                throw UsageError("--test-key-hex needs 64 hex digits")
            }
            let signer = try SoftwareSigner(rawKey: raw)
            let h = payload.hashes()
            let sig = try signer.sign(SiteSigning.publishMessage(bundle: h.bundle, run: h.run, samples: h.samples,
                                                                 summary: h.summary, timestamp: timestamp))
            let headers: [String: String] = ["key": SiteSigning.base64url(signer.publicKeyX963),
                                             "timestamp": timestamp, "signature": SiteSigning.base64url(sig)]
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(headers).write(to: dir.appendingPathComponent("headers.json"))
        }
        print(dir.path)
    }
}

private extension Data {
    init?(hexString: String) {
        var out = Data()
        var it = hexString.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        self = out
    }
}
