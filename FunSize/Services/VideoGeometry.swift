import AVFoundation

/// How a video track's stored pixels map to the picture people should see.
///
/// SD captures often store 720×480 pixels that are meant to be shown at 640×480 (4:3).
/// Files say this in one of two ways, sometimes both:
/// - a scale in the track's transform (720 × 0.889 = 640), or
/// - a pixel aspect ratio tag (10:11) plus a clean aperture (704 wide), so 704 × 10/11 = 640.
/// Only one of them may be applied, or the picture gets squeezed twice (582×480).
nonisolated struct VideoGeometry: Sendable {
    /// Pixel size of the frames as stored.
    let encodedSize: CGSize
    /// Maps stored pixels to the displayed picture, including any rotation.
    let transform: CGAffineTransform

    /// Size of the picture as it should be shown (after shape correction and rotation).
    var displaySize: CGSize {
        let rect = CGRect(origin: .zero, size: encodedSize).applying(transform)
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    init(encodedSize: CGSize, transform: CGAffineTransform) {
        self.encodedSize = encodedSize
        self.transform = transform
    }

    init(format: CMFormatDescription?, naturalSize: CGSize, preferredTransform: CGAffineTransform) {
        guard let format else {
            self.init(encodedSize: naturalSize, transform: preferredTransform)
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let encoded = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))

        if Self.hasScale(preferredTransform) {
            // The file's own transform already corrects the shape. Use it as-is.
            self.init(encodedSize: encoded, transform: preferredTransform)
            return
        }

        // Otherwise correct the shape from the pixel aspect tag. Measuring with the clean
        // aperture gives the standard sizes: 640×480 for 4:3 NTSC, 854×480 for 16:9.
        let hasPixelAspect = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) != nil
        let shaped = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: hasPixelAspect)
        let scale = CGAffineTransform(
            scaleX: encoded.width > 0 ? shaped.width / encoded.width : 1,
            y: encoded.height > 0 ? shaped.height / encoded.height : 1
        )
        self.init(encodedSize: encoded, transform: scale.concatenating(preferredTransform))
    }

    static func load(_ track: AVAssetTrack) async throws -> VideoGeometry {
        let (formats, naturalSize, preferredTransform) = try await track.load(.formatDescriptions, .naturalSize, .preferredTransform)
        return VideoGeometry(format: formats.first, naturalSize: naturalSize, preferredTransform: preferredTransform)
    }

    /// True when the transform resizes the picture, not just rotates or flips it.
    private static func hasScale(_ t: CGAffineTransform) -> Bool {
        let xScale = (t.a * t.a + t.b * t.b).squareRoot()
        let yScale = (t.c * t.c + t.d * t.d).squareRoot()
        return abs(xScale - 1) > 0.001 || abs(yScale - 1) > 0.001
    }
}
