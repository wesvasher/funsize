import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// Scale, position, and background: drawing, saving, and exporting (with transparency).
struct FrameLayoutTests {
    /// One pixel of `image` as RGBA 0…255 (premultiplied), `y` counted from the top.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }

    private static func render(_ image: CIImage) -> CGImage {
        CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    @Test func halfSizeLeavesBackgroundAround() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frame)
        let blue = RGBAColor(red: 0, green: 0, blue: 1)

        let half = Self.render(FrameLayoutStage.apply(red, layout: FrameLayout(scale: 0.5, backgroundColor: blue),
                                                      frame: frame, checkerboard: false))
        #expect(half.width == 200 && half.height == 100, "the frame keeps its size")
        #expect(Self.pixel(half, x: 100, y: 50)[0] > 240, "red in the middle")
        #expect(Self.pixel(half, x: 5, y: 5)[2] > 240, "blue around it")
        #expect(Self.pixel(half, x: 45, y: 50)[2] > 240, "the picture is 100 wide, from 50 to 150")
        #expect(Self.pixel(half, x: 55, y: 50)[0] > 240)

        // Moved right by a quarter of the frame and up by a quarter.
        let moved = Self.render(FrameLayoutStage.apply(
            red, layout: FrameLayout(scale: 0.5, offsetX: 0.25, offsetY: 0.25, backgroundColor: blue),
            frame: frame, checkerboard: false))
        #expect(Self.pixel(moved, x: 140, y: 30)[0] > 240, "up is toward the top of the picture")
        #expect(Self.pixel(moved, x: 60, y: 50)[2] > 240)

        let clear = Self.render(FrameLayoutStage.apply(red, layout: FrameLayout(scale: 0.5, background: .transparent),
                                                       frame: frame, checkerboard: false))
        #expect(Self.pixel(clear, x: 5, y: 5)[3] == 0, "transparent around it")
        #expect(Self.pixel(clear, x: 100, y: 50)[3] == 255)
        let checked = Self.render(FrameLayoutStage.apply(red, layout: FrameLayout(scale: 0.5, background: .transparent),
                                                         frame: frame, checkerboard: true))
        #expect(Self.pixel(checked, x: 5, y: 5)[3] == 255, "the viewer shows a checkerboard instead")
    }

    @Test @MainActor func clipsSaveTheirFraming() throws {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        #expect(clip.record.layout == nil)
        clip.layout = FrameLayout(scale: 0.5, offsetX: 0.1, offsetY: -0.2, background: .transparent)
        let record = try JSONDecoder().decode(ProjectFile.ClipRecord.self, from: JSONEncoder().encode(clip.record))
        let copy = Clip(url: URL(filePath: "/tmp/a.mov"))
        copy.apply(record)
        #expect(copy.layout == clip.layout)
        #expect(!clip.isAtDefaults)
        clip.resetAll()
        #expect(clip.layout == FrameLayout())
    }

    @Test func settingsCountFramingOnlyWhenItChangesSomething() {
        var settings = EnhanceSettings()
        #expect(!settings.isActive)
        settings.layout = FrameLayout(scale: 0.5)
        #expect(settings.isActive)
        // Moving a slider doesn't rebuild the preview.
        var other = settings
        other.layout = FrameLayout(scale: 0.7, offsetX: 0.3)
        #expect(settings.structure == other.structure)
        #expect(settings.timingOnly.layout == settings.layout, "Show Original keeps the framing")
    }

    /// Exports a red clip at half size and reads back the corner and middle.
    private func export(_ layout: FrameLayout, preset: ExportPreset) async throws -> (corner: [UInt8], middle: [UInt8]) {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 320, height: 240)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255  // BGRA red
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let playable = try await Enhancer.makePlayable(url: url, settings: EnhanceSettings(layout: layout))
        let job = ExportManager.test().export(asset: playable.asset, videoComposition: playable.videoComposition,
                                              name: "framed", preset: preset, folder: dir)
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: job.outputURL))
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        #expect(image.width == 320 && image.height == 240)
        return (Self.pixel(image, x: 4, y: 4), Self.pixel(image, x: 160, y: 120))
    }

    @Test func exportsDrawTheBackgroundColor() async throws {
        let green = RGBAColor(red: 0, green: 1, blue: 0)
        let result = try await export(FrameLayout(scale: 0.5, backgroundColor: green), preset: .builtIn("ProRes 422"))
        #expect(result.corner[1] > 200 && result.corner[0] < 100 && result.corner[2] < 60, "\(result.corner)")
        #expect(result.middle[0] > 150 && result.middle[1] < 100, "\(result.middle)")
    }

    @Test func proRes4444KeepsTransparency() async throws {
        var preset = ExportPreset.builtIn("ProRes 422")
        preset.video?.codec = .proRes4444
        let result = try await export(FrameLayout(scale: 0.5, background: .transparent), preset: preset)
        #expect(result.corner[3] < 10, "clear around the picture: \(result.corner)")
        #expect(result.middle[3] > 245, "\(result.middle)")
    }
}
