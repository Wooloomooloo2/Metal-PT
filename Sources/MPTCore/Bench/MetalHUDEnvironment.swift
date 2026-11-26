import Foundation

/// The environment that makes a Metal app log its frame times (one `metal-HUD:` line a second, to the unified log and
/// stderr). Measured on this Mac (docs/hardware-baseline.md, "Metal HUD hidden"): logging needs `MTL_HUD_ENABLED=1` as
/// well as `MTL_HUD_LOG_ENABLED=1` (the log alone, or `MTL_HUD_ENABLED=0`, logs nothing), and `MTL_HUD_OPACITY=0`
/// hides Apple's on-screen HUD while the log is unchanged. A game reads these once, at launch.
public enum MetalHUDEnvironment {
    public static let enabled = "MTL_HUD_ENABLED"
    public static let log = "MTL_HUD_LOG_ENABLED"
    public static let opacity = "MTL_HUD_OPACITY"
    /// The two variables logging needs (both "1").
    public static let required = [enabled, log]
    /// Every variable Metal-PT may set: what a turn-off or quit hands back.
    public static let all = [enabled, log, opacity]
    /// `MTL_HUD_OPACITY` while Apple's HUD is hidden.
    public static let hiddenOpacity = "0"

    /// The variables to set: logging on, and Apple's HUD hidden unless `showHUD`.
    public static func values(showHUD: Bool) -> [String: String] {
        var env = [enabled: "1", log: "1"]
        if !showHUD { env[opacity] = hiddenOpacity }
        return env
    }
}
