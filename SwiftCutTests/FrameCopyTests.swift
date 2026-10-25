import AppKit
import AVFoundation
import Testing
@testable import SwiftCut

/// Copy Frame in the video toolbar.
struct FrameCopyTests {
    @Test func copiesTheFrameAsShownAtFullSize() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 1920, height: 1080)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        // Black and white, so the copy must include the grade to come out gray.
        clip.grade.saturation = -1
        let controller = ClipPlayerController()
        controller.load(clip)
        await controller.applyEffects()
        for _ in 0..<300 where controller.player.currentItem?.status != .readyToPlay {
            try await Task.sleep(for: .milliseconds(10))
        }

        let image = try await controller.currentFrameImage()
        #expect(image.width == 1920 && image.height == 1080)
        let pixel = Self.centerPixel(image)
        #expect(abs(Int(pixel[0]) - Int(pixel[2])) < 12, "should be gray: \(pixel)")

        let pasteboard = NSPasteboard(name: .init("SwiftCutTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try await FrameClipboard.copy(image, to: pasteboard)
        let png = try #require(pasteboard.data(forType: .png))
        let pasted = try #require(NSBitmapImageRep(data: png))
        #expect(pasted.pixelsWide == 1920 && pasted.pixelsHigh == 1080)
        #expect(pasteboard.data(forType: .tiff) != nil)
    }

    @Test func nothingToCopyWithoutAVideo() async {
        await #expect(throws: (any Error).self) {
            try await ClipPlayerController().currentFrameImage()
        }
    }

    static func centerPixel(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}

/// Export Images in the video toolbar.
struct FrameExportTests {
    @Test func visiblePartOfThePicture() {
        let display = CGSize(width: 1920, height: 1080), viewport = CGSize(width: 960, height: 540)
        // Centered at 2× the viewer: the middle half.
        #expect(ViewerZoom.visibleFraction(offset: .zero, display: display, viewport: viewport)
                == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        // Moved all the way right and down: the top-left quarter.
        #expect(ViewerZoom.visibleFraction(offset: CGSize(width: 480, height: 270), display: display, viewport: viewport)
                == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        // Smaller than the viewer: all of it.
        #expect(ViewerZoom.visibleFraction(offset: .zero, display: CGSize(width: 480, height: 270), viewport: viewport)
                == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func cropsAndResizesTheView() throws {
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Left half red, right half blue.
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        let image = context.makeImage()!

        let right = try FrameClipboard.crop(image, to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                                            size: CGSize(width: 400, height: 400))
        #expect(right.width == 400 && right.height == 400)
        let pixel = FrameCopyTests.centerPixel(right)
        #expect(pixel[2] > 200 && pixel[0] < 40, "should be blue: \(pixel)")
    }

    @Test func savesPNGsWithoutReplacingFiles() throws {
        let dir = try TestVideo.tempDirectory()
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let first = try FrameClipboard.savePNG(image, named: "Clip: Take 1/2 Frame 5", in: dir)
        let second = try FrameClipboard.savePNG(image, named: "Clip: Take 1/2 Frame 5", in: dir)
        #expect(first.lastPathComponent == "Clip- Take 1-2 Frame 5.png")
        #expect(second.lastPathComponent == "Clip- Take 1-2 Frame 5 2.png")
        #expect(NSBitmapImageRep(data: try Data(contentsOf: second))?.pixelsWide == 8)
    }
}
