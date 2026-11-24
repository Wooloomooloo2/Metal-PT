import Foundation
import MPTCore

/// The app's data folders (`runs`, `projects`, `exports`). Order (ruling R1): `$MPT_DATA_ROOT` (dev/test isolation)
/// ?? the Settings data-folder value ?? `~/Documents/Metal-PT`, each with `name` appended.
public enum AppFolders {
    public static func url(_ name: String, setting: String?, env: [String: String]) -> URL {
        let envSet = !(env["MPT_DATA_ROOT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let root = setting.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let override = envSet ? nil : root.map { ($0 as NSString).appendingPathComponent(name) }
        return DataRoot.resolve(override: override, env: env, name: name)
    }
}
