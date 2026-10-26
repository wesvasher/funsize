import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Puts still frames on the clipboard.
enum FrameClipboard {
    /// The player item's frame at its current time, at full size, as the viewer shows it
    /// (through its video composition: effects, color, timeline layout).
    static func currentFrame(of item: AVPlayerItem) async throws -> CGImage {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: item.currentTime()).image
    }

    /// Copies `image` as PNG (full quality, keeps its color space), plus TIFF for apps that only
    /// read that. The encoding runs off the main thread: a 4K frame takes a moment.
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) async throws {
        let (png, tiff) = try await Task.detached(priority: .userInitiated) {
            (try encode(image, as: .png), try encode(image, as: .tiff))
        }.value
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
    }

    /// Saves `image` as a PNG file in `folder`, adding a number if the name is taken.
    /// Returns where it went.
    nonisolated static func savePNG(_ image: CGImage, named name: String, in folder: URL) throws -> URL {
        let data = try encode(image, as: .png)
        // Subclip names are typed by the user; "/" and ":" can't be in a file name.
        let name = name.replacing("/", with: "-").replacing(":", with: "-")
        var url = folder.appending(path: "\(name).png")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(name) \(number).png")
            number += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The part of `image` inside `fraction` (0…1 from the top left), resized to `size` pixels.
    nonisolated static func crop(_ image: CGImage, to fraction: CGRect, size: CGSize) throws -> CGImage {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: fraction.minX * full.width, y: fraction.minY * full.height,
                          width: fraction.width * full.width, height: fraction.height * full.height)
            .integral.intersection(full)
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            throw EnhanceError.failed("Nothing of the picture is in view.")
        }
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        if width == cropped.width && height == cropped.height { return cropped }

        // Keep the frame's own color space when a bitmap can use it (HDR and wide color).
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EnhanceError.failed("Couldn't make an image of the view.") }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw EnhanceError.failed("Couldn't make an image of the view.") }
        return result
    }

    nonisolated static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EnhanceError.failed("Couldn't make an image of the frame.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EnhanceError.failed("Couldn't make an image of the frame.")
        }
        return data as Data
    }
}
