import Testing
@testable import MPTCore

@Suite struct YouTubeLinkTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "  https://youtu.be/dQw4w9WgXcQ  ",
    ])
    func accepts(_ s: String) {
        #expect(YouTubeLink.videoID(from: s) == "dQw4w9WgXcQ")
    }

    @Test(arguments: [
        "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
        "https://evil.com/youtube.com/watch?v=dQw4w9WgXcQ",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com@evil.com/watch?v=dQw4w9WgXcQ",
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/redirect?q=https://evil.com&v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",
        "https://www.youtube.com/watch?v=dQw4w9WgX!Q",
        "https://youtu.be/dQw4w9WgXc",
        "https://youtu.be/dQw4w9WgXc/extra",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/dQw4w9WgXcQ",
        "ftp://youtu.be/dQw4w9WgXcQ",
        "dQw4w9WgXcQ",
        "",
    ])
    func rejects(_ s: String) {
        #expect(YouTubeLink.videoID(from: s) == nil)
    }

    @Test func canonicalURL() {
        #expect(YouTubeLink.canonicalURL(id: "dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }
}
