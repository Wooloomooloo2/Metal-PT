import Foundation

/// Store app IDs read from a game process's environment (Steam sets these for the game, and a Wine game launched
/// by Steam inherits them).
public enum StoreAppID {
    /// `steam:<digits>` from `SteamAppId`, else `SteamGameId`; a value must be 1-10 ASCII digits and not zero.
    public static func steam(from env: [String: String]) -> String? {
        for key in ["SteamAppId", "SteamGameId"] {
            guard let v = env[key], (1...10).contains(v.utf8.count),
                  v.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  v.utf8.contains(where: { $0 != 0x30 }) else { continue }
            return "steam:\(v)"
        }
        return nil
    }
}
