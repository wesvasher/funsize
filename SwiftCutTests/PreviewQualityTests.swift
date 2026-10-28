import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

/// The viewers' Quality menu: lighter previews draw a smaller picture; exports don't change.
struct PreviewQualityTests {
    @Test func previewSizesShrinkButNotTooFar() {
        let framing = EnhanceSettings(layout: FrameLayout(scale: 0.5))
        let hd = CGSize(width: 1920, height: 1080)
        #expect(Enhancer.previewSize(displaySize: hd, settings: framing, divisor: 1) == hd)
        #expect(Enhancer.previewSize(displaySize: hd, settings: framing, divisor: 2) == CGSize(width: 960, height: 540))
        #expect(Enhancer.previewSize(displaySize: hd, settings: framing, divisor: 8) == CGSize(width: 240, height: 136))
        // A small video goes only as small as 90 pixels high.
        let small = CGSize(width: 320, height: 240)
        #expect(Enhancer.previewSize(displaySize: small, settings: framing, divisor: 8) == CGSize(width: 160, height: 120))
        #expect(PreviewQuality.allCases.map(\.divisor) == [1, 2, 4, 8])
    }

    private static func redVideo() async throws -> URL {
        let dir = try TestVideo.tempDirectory()
        return try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 640, height: 480)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255  // BGRA red
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    @Test func clipPreviewRunsEffectsSmaller() async throws {
        let url = try await Self.redVideo()
        let settings = EnhanceSettings(layout: FrameLayout(scale: 0.5))
        let full = try await Enhancer.makePlayable(url: url, settings: settings)
        #expect(full.videoComposition?.renderSize == CGSize(width: 640, height: 480), "exports stay full size")
        let quarter = try await Enhancer.makePlayable(url: url, settings: settings, previewDivisor: 4)
        #expect(quarter.videoComposition?.renderSize == CGSize(width: 160, height: 120))

        // The smaller frame still has the picture where the full one does.
        let image = try await FrameClipboard.frame(of: quarter.asset, videoComposition: quarter.videoComposition,
                                                   at: CMTime(seconds: 0.5, preferredTimescale: 600))
        #expect(image.width == 160 && image.height == 120)
    }

    @Test func timelinePreviewDrawsSmaller() async throws {
        let url = try await Self.redVideo()
        let plain = CompositionBuilder.Segment(url: url, start: 0, end: 0.5)
        let framed = CompositionBuilder.Segment(url: url, start: 0, end: 0.5,
                                                settings: EnhanceSettings(layout: FrameLayout(scale: 0.5)))
        let full = try await CompositionBuilder.build([framed, plain])
        #expect(full.videoComposition?.renderSize == CGSize(width: 640, height: 480))
        let half = try await CompositionBuilder.build([framed, plain], previewDivisor: 2)
        #expect(half.videoComposition?.renderSize == CGSize(width: 320, height: 240), "the frame size follows the full picture")

        for seconds in [0.25, 0.75] {
            let image = try await FrameClipboard.frame(of: half.composition, videoComposition: half.videoComposition,
                                                       at: CMTime(seconds: seconds, preferredTimescale: 600))
            #expect(image.width == 320 && image.height == 240)
        }
    }
}
