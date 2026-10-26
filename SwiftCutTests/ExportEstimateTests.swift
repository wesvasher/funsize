import Foundation
import Testing
@testable import SwiftCut

struct ExportEstimateTests {
    let hd = ExportEstimate.Source(frameSize: CGSize(width: 1920, height: 1080), framesPerSecond: 29.97,
                                   duration: 60, audio: (48_000, 2))

    @Test func bitRateSettingsAreExact() {
        var preset = ExportPreset.defaults[0]
        preset.video?.rateControl = .bitRate
        preset.video?.bitRateMbps = 8
        preset.audio = ExportPreset.Audio(codec: .aac, bitRateKbps: 192)
        let estimate = ExportEstimate(preset: preset, source: hd)
        // 8 Mbps and 192 kbps for a minute: 60 MB + 1.44 MB.
        #expect(estimate.videoBytes == 60_000_000)
        #expect(estimate.audioBytes == 1_440_000)
        #expect(!estimate.isRough)
        #expect(abs(estimate.totalBytes - 61_440_000 * 1.01) < 1)
    }

    @Test func proResFollowsApplesRates() {
        let preset = ExportPreset.defaults.first { $0.video?.codec == .proRes422 }!
        let estimate = ExportEstimate(preset: preset, source: hd)
        // ProRes 422 at 1080p29.97 is 147 Mbps.
        #expect(abs(estimate.videoBytes - 147_000_000 * 60 / 8) < 1000)
        // 4K is four times as much.
        let uhd = ExportEstimate(preset: preset, source: .init(frameSize: CGSize(width: 3840, height: 2160),
                                                               framesPerSecond: 29.97, duration: 60, audio: nil))
        #expect(abs(uhd.videoBytes / estimate.videoBytes - 4) < 0.001)
        #expect(uhd.audioBytes == 0)
    }

    @Test func presetSizeAndRateChangeTheEstimate() {
        let full = ExportEstimate(preset: ExportPreset.defaults[0], source: hd)
        let p720 = ExportEstimate(preset: ExportPreset.defaults.first { $0.name == "720p MP4" }!, source: hd)
        #expect(full.isRough && p720.isRough)
        #expect(p720.frameSize == CGSize(width: 1280, height: 720))
        #expect(p720.totalBytes < full.totalBytes)
        // HEVC is smaller than H.264 at the same quality.
        #expect(ExportEstimate.bitsPerPixel(quality: 0.8, codec: .hevc) < ExportEstimate.bitsPerPixel(quality: 0.8, codec: .h264))
        // A fixed frame rate in the preset wins over the source's.
        var at24 = ExportPreset.defaults[0]
        at24.video?.frameRate = 24
        #expect(ExportEstimate(preset: at24, source: hd).framesPerSecond == 24)
    }

    @Test func audioOnlyAndSilentTimelines() {
        let audioOnly = ExportPreset.defaults.first(where: \.isAudioOnly)!
        let estimate = ExportEstimate(preset: audioOnly, source: hd)
        #expect(estimate.videoBytes == 0 && estimate.frameSize == .zero)
        #expect(estimate.audioBytes == 256_000 * 60 / 8)
        var silent = hd
        silent.audio = nil
        #expect(ExportEstimate(preset: ExportPreset.defaults[0], source: silent).audioBytes == 0)
    }

    @Test func exportPresetIsSavedWithTimelineSettings() throws {
        let id = ExportPreset.defaults[2].id
        let settings = TimelineSettings(aspect: .square, exportPresetID: id)
        let decoded = try JSONDecoder().decode(TimelineSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.exportPresetID == id && decoded == settings)
        #expect(!TimelineSettings(exportPresetID: id).isDefault)
    }
}
