import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

struct TimelineSettingsTests {
    let hd = CGSize(width: 1920, height: 1080)

    @Test func automaticUsesTheFirstClip() {
        #expect(TimelineSettings().renderSize(firstClip: CGSize(width: 1441, height: 1080)) == CGSize(width: 1440, height: 1080))
        #expect(TimelineSettings().renderSize(firstClip: nil) == hd)
    }

    @Test func aspectAndResolutionMakeTheFrame() {
        #expect(TimelineSettings(aspect: .widescreen, resolution: .uhd2160).renderSize(firstClip: hd) == CGSize(width: 3840, height: 2160))
        #expect(TimelineSettings(aspect: .standard, resolution: .sd480).renderSize(firstClip: hd) == CGSize(width: 640, height: 480))
        // Tall frames: the resolution is the shorter side (the width).
        #expect(TimelineSettings(aspect: .vertical, resolution: .hd1080).renderSize(firstClip: hd) == CGSize(width: 1080, height: 1920))
        #expect(TimelineSettings(aspect: .portrait, resolution: .hd1080).renderSize(firstClip: hd) == CGSize(width: 1080, height: 1350))
        #expect(TimelineSettings(aspect: .square, resolution: .hd720).renderSize(firstClip: hd) == CGSize(width: 720, height: 720))
        // Only one set: the other follows the first clip.
        #expect(TimelineSettings(aspect: .square).renderSize(firstClip: hd) == CGSize(width: 1080, height: 1080))
        #expect(TimelineSettings(resolution: .hd720).renderSize(firstClip: hd) == CGSize(width: 1280, height: 720))
    }

    @Test func savedInProjectsAndOldProjectsOpen() throws {
        let store = ProjectStore(exporter: ExportManager.test())
        store.timelineSettings = TimelineSettings(aspect: .vertical, resolution: .hd1080, frameRate: .fps29_97, fit: .fill)
        let data = try JSONEncoder().encode(store.projectFile)
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        #expect(file.timelineSettings == store.timelineSettings)

        let other = ProjectStore(exporter: ExportManager.test())
        other.apply(file)
        #expect(other.timelineSettings == store.timelineSettings)

        // A project from before timeline settings: Automatic.
        let old = try JSONDecoder().decode(ProjectFile.self, from: Data(#"{"version":2,"clips":[],"timeline":[]}"#.utf8))
        #expect(old.timelineSettings.isDefault)
    }

    @Test func fillCoversTheFrameAndFitShowsItAll() {
        let square = CGSize(width: 1000, height: 1000)
        let fit = CompositionBuilder.fitTransform(natural: square, preferred: .identity, into: hd)
        let fill = CompositionBuilder.fitTransform(natural: square, preferred: .identity, into: hd, fill: true)
        let fitRect = CGRect(origin: .zero, size: square).applying(fit)
        let fillRect = CGRect(origin: .zero, size: square).applying(fill)
        #expect(abs(fitRect.height - 1080) < 0.01 && abs(fitRect.midX - 960) < 0.01)
        #expect(abs(fillRect.width - 1920) < 0.01 && abs(fillRect.midY - 540) < 0.01)
    }

    @Test func builtTimelineUsesTheSettings() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "a", seconds: 1, size: CGSize(width: 1280, height: 720))
        let segment = CompositionBuilder.Segment(url: url, start: 0, end: 1)

        let automatic = try await CompositionBuilder.build([segment])
        #expect(automatic.videoComposition?.renderSize == CGSize(width: 1280, height: 720))

        let settings = TimelineSettings(aspect: .vertical, resolution: .hd1080, frameRate: .fps25)
        let custom = try await CompositionBuilder.build([segment], settings: settings)
        #expect(custom.videoComposition?.renderSize == CGSize(width: 1080, height: 1920))
        #expect(custom.videoComposition?.frameDuration == CMTime(value: 1, timescale: 25))
    }

    @Test func presetsSaveReplaceAndDelete() throws {
        let defaults = try #require(UserDefaults(suiteName: "TimelinePresetTests-\(UUID())"))
        let store = TimelinePresetStore(defaults: defaults)
        store.save(name: "Vertical", settings: TimelineSettings(aspect: .vertical))
        store.save(name: "  ", settings: TimelineSettings())
        #expect(store.presets.map(\.name) == ["Vertical"])
        // Same name (any case) replaces.
        store.save(name: "vertical", settings: TimelineSettings(aspect: .vertical, frameRate: .fps30))
        #expect(store.presets.count == 1 && store.presets[0].settings.frameRate == .fps30)
        // Kept across launches.
        #expect(TimelinePresetStore(defaults: defaults).presets == store.presets)
        store.delete(store.presets[0])
        #expect(TimelinePresetStore(defaults: defaults).presets.isEmpty)
    }

    @Test func timelineFrameGrabUsesTheTimelineFormat() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "a", seconds: 1, size: CGSize(width: 1280, height: 720))
        let segment = CompositionBuilder.Segment(url: url, start: 0, end: 1)
        let result = try await CompositionBuilder.build([segment], settings: TimelineSettings(aspect: .vertical, resolution: .hd1080))
        let item = await AVPlayerItem(asset: result.composition)
        await MainActor.run { item.videoComposition = result.videoComposition }
        let image = try await FrameClipboard.currentFrame(of: item)
        #expect(image.width == 1080 && image.height == 1920)
    }
}
