import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import SwiftCut

/// The timeline shows each clip with its own effects and color, as the clip viewer does.
struct TimelineEffectsTests {
    /// Top half red, bottom half blue (BGRA).
    static func redOverBlue(in dir: URL, name: String, size: CGSize = CGSize(width: 640, height: 480)) async throws -> URL {
        try await TestVideo.make(in: dir, name: name, seconds: 2, size: size) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let height = CVPixelBufferGetHeight(pixels), width = CVPixelBufferGetWidth(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * row + x * 4
                    let top = y < height / 2
                    base[i] = top ? 30 : 220      // blue
                    base[i + 1] = 30               // green
                    base[i + 2] = top ? 220 : 30  // red
                    base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    /// The timeline's frame at `seconds`.
    static func frame(_ result: CompositionBuilder.Result, at seconds: Double) async throws -> CGImage {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Color at a spot given as fractions of the width and height (from the top left), 0…1.
    static func color(_ image: CGImage, x: Double, y: Double) -> SIMD3<Double> {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = Int(Double(image.width - 1) * x), py = Int(Double(image.height - 1) * y)
        context.draw(image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
    }

    @Test func plainClipIsUprightAndLetterboxed() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await Self.redOverBlue(in: dir, name: "plain")
        // A 4:3 clip in a 16:9 frame: black bars left and right.
        let result = try await CompositionBuilder.build([.init(url: url, start: 0, end: 2)],
                                                        settings: TimelineSettings(aspect: .widescreen, resolution: .sd480))
        let image = try await Self.frame(result, at: 0.5)
        #expect(image.width == 852 && image.height == 480)
        let top = Self.color(image, x: 0.5, y: 0.25), bottom = Self.color(image, x: 0.5, y: 0.75)
        #expect(top.x > 0.6 && top.z < 0.3, "red on top: \(top)")
        #expect(bottom.z > 0.6 && bottom.x < 0.3, "blue on the bottom: \(bottom)")
        let bar = Self.color(image, x: 0.02, y: 0.5)
        #expect(bar.x < 0.05 && bar.z < 0.05, "black bar: \(bar)")
    }

    @Test func eachClipKeepsItsOwnColor() async throws {
        let dir = try TestVideo.tempDirectory()
        let a = try await Self.redOverBlue(in: dir, name: "a")
        let b = try await Self.redOverBlue(in: dir, name: "b")
        var blackAndWhite = EnhanceSettings()
        blackAndWhite.lut = AppliedLUT(lut: ColorLUT.builtIns.first { $0.name == "Black & White" }!, intensity: 1)
        var desaturated = EnhanceSettings()
        desaturated.grade = ColorGrade(saturation: -1)
        let result = try await CompositionBuilder.build([
            .init(url: a, start: 0, end: 1),
            .init(url: b, start: 0, end: 1, settings: blackAndWhite),
            .init(url: a, start: 0, end: 1, settings: desaturated),
        ])
        #expect(abs(result.duration - 3) < 0.05)

        let first = Self.color(try await Self.frame(result, at: 0.5), x: 0.5, y: 0.25)
        #expect(first.x - first.z > 0.4, "first clip untouched (red): \(first)")
        for seconds in [1.5, 2.5] {
            let gray = Self.color(try await Self.frame(result, at: seconds), x: 0.5, y: 0.25)
            #expect(abs(gray.x - gray.z) < 0.05, "gray at \(seconds) s: \(gray)")
        }
    }

    @Test func deinterlacedClipDoublesTheTimelineRate() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await Self.redOverBlue(in: dir, name: "interlaced")
        var settings = EnhanceSettings()
        settings.fieldOrder = .topFirst
        let result = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1, settings: settings)])
        let duration = try #require(result.videoComposition?.frameDuration)
        #expect(abs(duration.seconds - 1.0 / 60) < 0.0005, "60 frames a second from 30: \(duration.seconds)")
        _ = try await Self.frame(result, at: 0.5)
    }

    @Test func noiseReductionRendersOnTheTimeline() async throws {
        guard Enhancer.canReduceNoise else { return }
        let dir = try TestVideo.tempDirectory()
        let plain = try await Self.redOverBlue(in: dir, name: "plain")
        let noisy = try await EnhanceTests.noisyClip(in: dir)
        var settings = EnhanceSettings()
        settings.denoiseStrength = 1
        // The noisy clip second, so its neighbor frames have to line up after the first clip.
        let result = try await CompositionBuilder.build([
            .init(url: plain, start: 0, end: 1),
            .init(url: noisy, start: 0.5, end: 1.5, settings: settings),
        ])
        let image = try await Self.frame(result, at: 1.5)
        let center = Self.color(image, x: 0.5, y: 0.5)
        #expect(abs(center.x - 0.5) < 0.2, "gray noise picture: \(center)")
    }

    @Test @MainActor func thumbnailsShowTheClipsColor() async throws {
        let dir = try TestVideo.tempDirectory()
        let clip = Clip(url: try await Self.redOverBlue(in: dir, name: "thumbs"))
        await MediaLoader.load(clip)
        let original = try #require(clip.thumbnail(near: 0.5))
        let red = Self.color(original, x: 0.5, y: 0.25)
        #expect(red.x - red.z > 0.4, "original is red on top: \(red)")

        clip.lutID = ColorLUT.builtIns.first { $0.name == "Black & White" }!.id
        let gray = Self.color(try #require(clip.thumbnail(near: 0.5)), x: 0.5, y: 0.25)
        #expect(abs(gray.x - gray.z) < 0.05, "black and white: \(gray)")
        #expect(clip.poster.map { Self.color($0, x: 0.5, y: 0.25) }.map { abs($0.x - $0.z) < 0.05 } == true)

        // Switching the LUT off brings the original back.
        clip.lutEnabled = false
        #expect(clip.thumbnail(near: 0.5) === original)
    }
}
