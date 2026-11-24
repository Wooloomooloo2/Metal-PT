import Foundation

/// `UserDefaults` that keeps values in memory only (snapshot fixtures and tests): nothing reaches cfprefsd, so no
/// plist is left in `~/Library/Preferences`. Every accessor the app, `@AppStorage` and the tests use is overridden,
/// including `register(defaults:)` (a separate fallback layer, as in `UserDefaults`).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    /// The suite name is never written to: every read and write below stays in `values`.
    init() { super.init(suiteName: "metal-pt.memory")! }

    // MARK: - Reads

    override func object(forKey defaultName: String) -> Any? { values[defaultName] ?? registered[defaultName] }
    override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let u as URL: u
        case let s as String: URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        default: nil
        }
    }
    override func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let n as NSNumber: n.boolValue
        case let s as String: ["yes", "true", "1"].contains(s.lowercased())
        default: false
        }
    }
    override func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s) ?? 0
        default: 0
        }
    }
    override func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s) ?? 0
        default: 0
        }
    }
    override func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }
    override func dictionaryRepresentation() -> [String: Any] { registered.merging(values) { $1 } }

    // MARK: - Writes

    override func set(_ value: Any?, forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        values[defaultName] = value
        didChangeValue(forKey: defaultName)
    }
    override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    override func register(defaults registrationDictionary: [String: Any]) {
        registered.merge(registrationDictionary) { $1 }
    }
    override func removePersistentDomain(forName domainName: String) { values.removeAll() }
    override func synchronize() -> Bool { true }
}
