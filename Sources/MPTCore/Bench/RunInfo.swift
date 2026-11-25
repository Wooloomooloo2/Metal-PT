import Foundation

public struct RunInfo: Codable, Sendable {
    public struct Machine: Codable, Sendable {
        public var modelID: String
        public var chip: String
        public var gpuCores: Int?
        public var memoryGB: Int
        public var osVersion: String
        public var osBuild: String
        /// Top GPU clock (MHz) from the `pmgr` frequency table; nil when unknown (and in runs written before it).
        public var gpuMaxMHz: Int?
        /// The GPU frequency table (MHz per GPUPH state P1…Pn, rounded) from `pmgr`; nil when unknown (and in runs
        /// written before it). [?] P*n* ↔ entry *n* is unverified; the limiter analysis uses it to bound its clock rule.
        public var gpuClockTableMHz: [Int]?
        public init(modelID: String, chip: String, gpuCores: Int? = nil, memoryGB: Int,
                    osVersion: String, osBuild: String, gpuMaxMHz: Int? = nil, gpuClockTableMHz: [Int]? = nil) {
            self.modelID = modelID; self.chip = chip; self.gpuCores = gpuCores
            self.memoryGB = memoryGB; self.osVersion = osVersion; self.osBuild = osBuild
            self.gpuMaxMHz = gpuMaxMHz; self.gpuClockTableMHz = gpuClockTableMHz
        }
    }
    public struct Game: Codable, Sendable {
        public var exe: String
        public var title: String?
        public var storeAppID: String?
        public init(exe: String, title: String? = nil, storeAppID: String? = nil) {
            self.exe = exe; self.title = title; self.storeAppID = storeAppID
        }
        /// The title, nil when absent or empty (an empty title names nothing).
        public var titleText: String? { (title ?? "").isEmpty ? nil : title }
    }
    public struct Settings: Codable, Sendable {
        public var powerMode: String?
        public var onACAtStart: Bool?
        public var displayWidth: Int?
        public var displayHeight: Int?
        public var refreshHz: Double?
        public init(powerMode: String? = nil, onACAtStart: Bool? = nil, displayWidth: Int? = nil,
                    displayHeight: Int? = nil, refreshHz: Double? = nil) {
            self.powerMode = powerMode; self.onACAtStart = onACAtStart
            self.displayWidth = displayWidth; self.displayHeight = displayHeight; self.refreshHz = refreshHz
        }
    }
    /// What the user set in the game: preset, render resolution, upscaler and frame generation. Every field is
    /// optional (a run may carry some); unknown enum strings decode as nil so a newer file never fails to load.
    public struct Graphics: Codable, Sendable, Equatable, Hashable {
        public enum Preset: String, Codable, Sendable, CaseIterable { case low, medium, high, veryHigh, ultra, custom }
        public enum Upscaler: String, Codable, Sendable, CaseIterable { case off, metalfx, fsr, xess, dlss, other }
        public enum UpscalerMode: String, Codable, Sendable, CaseIterable {
            case quality, balanced, performance, ultraPerformance, native
        }

        public var preset: Preset?
        public var width: Int?
        public var height: Int?
        public var upscaler: Upscaler?
        public var upscalerMode: UpscalerMode?
        public var frameGeneration: Bool?

        public init(preset: Preset? = nil, width: Int? = nil, height: Int? = nil, upscaler: Upscaler? = nil,
                    upscalerMode: UpscalerMode? = nil, frameGeneration: Bool? = nil) {
            self.preset = preset; self.width = width; self.height = height; self.upscaler = upscaler
            self.upscalerMode = upscalerMode; self.frameGeneration = frameGeneration
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `try?` on decodeIfPresent: an unknown string (or a wrong type) is nil, never a thrown error.
            preset = (try? c.decodeIfPresent(Preset.self, forKey: .preset)) ?? nil
            width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? nil
            height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? nil
            upscaler = (try? c.decodeIfPresent(Upscaler.self, forKey: .upscaler)) ?? nil
            upscalerMode = (try? c.decodeIfPresent(UpscalerMode.self, forKey: .upscalerMode)) ?? nil
            frameGeneration = (try? c.decodeIfPresent(Bool.self, forKey: .frameGeneration)) ?? nil
        }

        /// Everything the website needs is set (a mode only when an upscaler is on).
        public var isComplete: Bool {
            guard preset != nil, width != nil, height != nil, let upscaler, frameGeneration != nil else { return false }
            return upscaler == .off || upscalerMode != nil
        }

        /// Resolutions offered in the edit sheet after the main display's own.
        public static let commonResolutions: [(Int, Int)] = [
            (1280, 800), (1920, 1080), (1920, 1200), (2560, 1440), (2560, 1600), (3024, 1964), (3456, 2234),
        ]

        /// "High · 2560×1440 · MetalFX Quality · FG off"; only the parts that are set.
        public var line: String {
            var parts: [String] = []
            if let preset { parts.append(preset.displayName) }
            if let width, let height { parts.append("\(width)×\(height)") }
            if let upscaler {
                parts.append(upscaler == .off ? "no upscaler"
                                              : [upscaler.displayName, upscalerMode?.displayName].compactMap { $0 }
                                                    .joined(separator: " "))
            }
            if let frameGeneration { parts.append(frameGeneration ? "FG on" : "FG off") }
            return parts.joined(separator: " · ")
        }
    }
    public struct UserFields: Codable, Sendable {
        public var label: String
        public var gameSettings: String
        public var notes: String
        /// A YouTube link (canonical form) to a video about this run; nil when none.
        public var videoURL: String?
        public init(label: String = "", gameSettings: String = "", notes: String = "", videoURL: String? = nil) {
            self.label = label; self.gameSettings = gameSettings; self.notes = notes; self.videoURL = videoURL
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            gameSettings = try c.decodeIfPresent(String.self, forKey: .gameSettings) ?? ""
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
            videoURL = try c.decodeIfPresent(String.self, forKey: .videoURL)
        }
    }

    public static let currentSchema = 1

    public var schema: Int
    public var appVersion: String
    public var machine: Machine
    public var game: Game
    public var stack: Stack
    public var settings: Settings
    /// The in-game graphics settings the user entered; nil when none (and in runs written before it).
    public var graphics: Graphics?
    public var user: UserFields
    public var start: Date
    public var end: Date?
    public var steadyStartS: Double?
    public var steadyEndS: Double?
    /// "log", "stderr" or "none"
    public var fpsSource: String
    public var warnings: [String]

    public init(schema: Int = RunInfo.currentSchema, appVersion: String, machine: Machine, game: Game,
                stack: Stack = Stack(), settings: Settings = Settings(), graphics: Graphics? = nil, user: UserFields = UserFields(),
                start: Date, end: Date? = nil, steadyStartS: Double? = nil, steadyEndS: Double? = nil,
                fpsSource: String = "none", warnings: [String] = []) {
        self.schema = schema; self.appVersion = appVersion; self.machine = machine; self.game = game
        self.stack = stack; self.settings = settings; self.graphics = graphics; self.user = user; self.start = start; self.end = end
        self.steadyStartS = steadyStartS; self.steadyEndS = steadyEndS
        self.fpsSource = fpsSource; self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        machine = try c.decode(Machine.self, forKey: .machine)
        game = try c.decode(Game.self, forKey: .game)
        stack = try c.decodeIfPresent(Stack.self, forKey: .stack) ?? Stack()
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        graphics = (try? c.decodeIfPresent(Graphics.self, forKey: .graphics)) ?? nil
        user = try c.decodeIfPresent(UserFields.self, forKey: .user) ?? UserFields()
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        steadyStartS = try c.decodeIfPresent(Double.self, forKey: .steadyStartS)
        steadyEndS = try c.decodeIfPresent(Double.self, forKey: .steadyEndS)
        fpsSource = try c.decodeIfPresent(String.self, forKey: .fpsSource) ?? "none"
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

extension RunInfo.Graphics.Preset {
    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .veryHigh: "Very high"
        case .ultra: "Ultra"
        case .custom: "Custom"
        }
    }
}

extension RunInfo.Graphics.Upscaler {
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .metalfx: "MetalFX"
        case .fsr: "FSR"
        case .xess: "XeSS"
        case .dlss: "DLSS"
        case .other: "Other"
        }
    }
}

extension RunInfo.Graphics.UpscalerMode {
    public var displayName: String {
        switch self {
        case .quality: "Quality"
        case .balanced: "Balanced"
        case .performance: "Performance"
        case .ultraPerformance: "Ultra performance"
        case .native: "Native"
        }
    }
}
