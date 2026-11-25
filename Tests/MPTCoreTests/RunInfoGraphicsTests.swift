import Testing
import Foundation
@testable import MPTCore

@Suite struct RunInfoGraphicsTests {
    private func info(graphics: RunInfo.Graphics? = nil, videoURL: String? = nil) -> RunInfo {
        var i = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "M3 Pro", memoryGB: 36,
                                                          osVersion: "15.1", osBuild: "24B83"),
                        game: .init(exe: "g.exe"), start: Date(timeIntervalSince1970: 1_800_000_000))
        i.graphics = graphics
        i.user.videoURL = videoURL
        return i
    }

    private func roundTrip(_ i: RunInfo) throws -> (RunInfo, String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(i)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try dec.decode(RunInfo.self, from: data), String(decoding: data, as: UTF8.self))
    }

    @Test func graphicsRoundTrips() throws {
        let g = RunInfo.Graphics(preset: .veryHigh, width: 2560, height: 1440, upscaler: .metalfx,
                                 upscalerMode: .quality, frameGeneration: false)
        let (back, json) = try roundTrip(info(graphics: g, videoURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(back.graphics == g)
        #expect(back.user.videoURL == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(json.contains("\"graphics\""))
        #expect(json.contains("\"veryHigh\""))
    }

    @Test func absentFieldsStayAbsent() throws {
        let (back, json) = try roundTrip(info())
        #expect(back.graphics == nil)
        #expect(back.user.videoURL == nil)
        #expect(!json.contains("\"graphics\":{"))
        #expect(!json.contains("videoURL"))
    }

    @Test func oldJSONWithoutGraphicsDecodesNil() throws {
        let json = """
        {"schema":1,"appVersion":"0.2","machine":{"modelID":"M","chip":"c","memoryGB":8,"osVersion":"1","osBuild":"b"},
         "game":{"exe":"x"},"user":{"label":"l","gameSettings":"g","notes":"n"},"start":"2027-01-01T00:00:00Z"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let i = try dec.decode(RunInfo.self, from: Data(json.utf8))
        #expect(i.graphics == nil)
        #expect(i.user.videoURL == nil)
    }

    @Test func unknownEnumStringsDecodeAsNil() throws {
        let json = #"{"preset":"mega","width":1920,"height":1080,"upscaler":"magic","upscalerMode":"turbo","frameGeneration":true}"#
        let g = try JSONDecoder().decode(RunInfo.Graphics.self, from: Data(json.utf8))
        #expect(g.preset == nil)
        #expect(g.upscaler == nil)
        #expect(g.upscalerMode == nil)
        #expect(g.width == 1920)
        #expect(g.frameGeneration == true)
    }

    @Test func isCompleteCases() {
        var g = RunInfo.Graphics()
        #expect(!g.isComplete)
        g = .init(preset: .high, width: 1920, height: 1080, upscaler: .off, upscalerMode: nil, frameGeneration: false)
        #expect(g.isComplete)   // Off needs no mode
        g.upscaler = .fsr
        #expect(!g.isComplete)  // a mode is needed
        g.upscalerMode = .balanced
        #expect(g.isComplete)
        g.frameGeneration = nil
        #expect(!g.isComplete)
        g.frameGeneration = true
        g.width = nil
        #expect(!g.isComplete)
        g.width = 1920
        g.preset = nil
        #expect(!g.isComplete)
    }

    @Test func commonResolutionsAreTheAgreedList() {
        let r = RunInfo.Graphics.commonResolutions.map { "\($0.0)x\($0.1)" }
        #expect(r == ["1280x800", "1920x1080", "1920x1200", "2560x1440", "2560x1600", "3024x1964", "3456x2234"])
    }

    @Test func descriptionLine() {
        let g = RunInfo.Graphics(preset: .high, width: 2560, height: 1440, upscaler: .metalfx,
                                 upscalerMode: .quality, frameGeneration: false)
        #expect(g.line == "High · 2560×1440 · MetalFX Quality · FG off")
        let off = RunInfo.Graphics(preset: .ultra, width: 1920, height: 1080, upscaler: .off, frameGeneration: true)
        #expect(off.line == "Ultra · 1920×1080 · no upscaler · FG on")
    }
}
