import Foundation

/// Where Metal-PT keeps its folders (`runs`, `projects`, `exports`).
public enum DataRoot {
    /// `override` (tilde-expanded) if given; else `$MPT_DATA_ROOT/<name>` when that is set and not blank
    /// (tilde-expanded); else `~/Documents/Metal-PT/<name>`.
    public static func resolve(override: String?, env: [String: String], name: String) -> URL {
        if let override { return URL(fileURLWithPath: expand(override), isDirectory: true) }
        if let root = env["MPT_DATA_ROOT"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expand(root), isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Metal-PT", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    private static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}
