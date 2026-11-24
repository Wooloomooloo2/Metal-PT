import Foundation
import FWCore

// Line-buffer stdout so status lines survive Ctrl-C when piped to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    fwbench — record game benchmark runs (no root needed).

    \(RecordCommands.usage)
    \(CompareCommands.usage)
    \(HUDCommands.usage)
    """

if geteuid() == 0 {
    FileHandle.standardError.write(Data("fwbench must not run as root\n".utf8))
    exit(64)
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "record":
        try RecordCommands.record(Array(args.dropFirst()))
    case "run":
        try RecordCommands.run(Array(args.dropFirst()))
    case "ls":
        try RecordCommands.ls(Array(args.dropFirst()))
    case "summary":
        try RecordCommands.summary(Array(args.dropFirst()))
    case "stack":
        try RecordCommands.stack(Array(args.dropFirst()))
    case "compare":
        try CompareCommands.run(Array(args.dropFirst()))
    case "hud":
        try HUDCommands.run(Array(args.dropFirst()))
    case "help", "--help", "-h", nil:
        print(usage)
    case let command?:
        printError("unknown command: \(command)\n\n\(usage)")
        exit(64)
    }
} catch let error as UsageError {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

// MARK: - Shared helpers

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parses `--flag value` options; rejects unknown flags, missing values and stray positionals.
func parseOptions(_ args: [String], allowed: Set<String>) throws -> [String: String] {
    var result: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--"), allowed.contains(a) else { throw UsageError("unexpected argument '\(a)'") }
        guard i + 1 < args.count else { throw UsageError("\(a) needs a value") }
        result[a] = args[i + 1]
        i += 2
    }
    return result
}

func number(_ options: [String: String], _ name: String) throws -> Double? {
    guard let text = options[name] else { return nil }
    guard let v = Double(text), v.isFinite, v >= 0 else { throw UsageError("\(name) needs a number ≥ 0, got '\(text)'") }
    return v
}

/// `override` (tilde-expanded) if given, else `~/Documents/FW Benchmark/<name>`.
func benchFolder(_ name: String, override: String?) -> URL {
    if let override { return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true) }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    return docs.appendingPathComponent("FW Benchmark/\(name)", isDirectory: true)
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Runs a tool and returns its stdout (stderr discarded).
func captureTool(_ path: String, _ arguments: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Runs a tool and waits; returns its exit status.
@discardableResult
func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
