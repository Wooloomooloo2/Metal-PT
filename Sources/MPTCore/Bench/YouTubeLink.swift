import Foundation

/// Accepts only YouTube video links, so a run's `videoURL` can never point elsewhere.
public enum YouTubeLink {
    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]
    private static let shortHost = "youtu.be"

    /// The 11-character video ID of an https YouTube link (`/watch?v=ID`, `youtu.be/ID`, `/shorts/ID`, `/live/ID`),
    /// else nil: other hosts (including look-alikes such as `youtube.com.evil.com`), http, user info, ports and
    /// IDs of another shape are all refused.
    public static func videoID(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil,
              let host = c.host?.lowercased() else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let id: String?
        if host == shortHost {
            id = parts.count == 1 ? parts[0] : nil
        } else if hosts.contains(host) {
            if c.path == "/watch" {
                id = c.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count == 2, parts[0] == "shorts" || parts[0] == "live" {
                id = parts[1]
            } else {
                id = nil
            }
        } else {
            id = nil
        }
        guard let id, isValidID(id) else { return nil }
        return id
    }

    public static func canonicalURL(id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    private static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
        }
    }
}
