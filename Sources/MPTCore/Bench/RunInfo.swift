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
    public struct UserFields: Codable, Sendable {
        public var label: String
        public var gameSettings: String
        public var notes: String
        public init(label: String = "", gameSettings: String = "", notes: String = "") {
            self.label = label; self.gameSettings = gameSettings; self.notes = notes
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            gameSettings = try c.decodeIfPresent(String.self, forKey: .gameSettings) ?? ""
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }
    }

    public static let currentSchema = 1

    public var schema: Int
    public var appVersion: String
    public var machine: Machine
    public var game: Game
    public var stack: Stack
    public var settings: Settings
    public var user: UserFields
    public var start: Date
    public var end: Date?
    public var steadyStartS: Double?
    public var steadyEndS: Double?
    /// "log", "stderr" or "none"
    public var fpsSource: String
    public var warnings: [String]

    public init(schema: Int = RunInfo.currentSchema, appVersion: String, machine: Machine, game: Game,
                stack: Stack = Stack(), settings: Settings = Settings(), user: UserFields = UserFields(),
                start: Date, end: Date? = nil, steadyStartS: Double? = nil, steadyEndS: Double? = nil,
                fpsSource: String = "none", warnings: [String] = []) {
        self.schema = schema; self.appVersion = appVersion; self.machine = machine; self.game = game
        self.stack = stack; self.settings = settings; self.user = user; self.start = start; self.end = end
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
        user = try c.decodeIfPresent(UserFields.self, forKey: .user) ?? UserFields()
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        steadyStartS = try c.decodeIfPresent(Double.self, forKey: .steadyStartS)
        steadyEndS = try c.decodeIfPresent(Double.self, forKey: .steadyEndS)
        fpsSource = try c.decodeIfPresent(String.self, forKey: .fpsSource) ?? "none"
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
