import Foundation
import MPTCore

/// The app's data folders (`runs`, `projects`, `exports`). Order (ruling R1): `$MPT_DATA_ROOT` (dev/test isolation)
/// ?? the Settings data-folder value (trimmed, `~` expanded) ?? `~/Documents/Metal-PT`, each with `name` appended.
public enum AppFolders {
    public static func url(_ name: String, setting: String?, env: [String: String]) -> URL {
        let override = envRoot(env) != nil ? nil : settingRoot(setting).map {
            (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent(name)
        }
        return DataRoot.resolve(override: override, env: env, name: name)
    }

    /// The data root itself (what Settings shows), in the same order as `url`.
    public static func root(setting: String?, env: [String: String]) -> URL {
        url("runs", setting: setting, env: env).deletingLastPathComponent()
    }

    /// `$MPT_DATA_ROOT` when set and not blank: it overrides the Settings value (Settings shows it locked).
    public static func envRoot(_ env: [String: String]) -> String? {
        guard let v = env["MPT_DATA_ROOT"], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return v
    }

    /// `~/Library/Application Support/Metal-PT`: the website publishing key (`site-key`). Shared by the app and
    /// `mpt publish`, so runs published from either can be removed from either. Not created here.
    public static func support() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: false).appendingPathComponent("Metal-PT", isDirectory: true)
    }

    private static func settingRoot(_ setting: String?) -> String? {
        setting.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
