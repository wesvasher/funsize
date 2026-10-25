import AVFoundation
import UniformTypeIdentifiers

/// Reads a clip's metadata and generates its filmstrip thumbnails.
enum MediaLoader {
    static let thumbnailCount = 12

    static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) ?? false
    }

    static func load(_ clip: Clip) async {
        let asset = AVURLAsset(url: clip.url)
        do {
            clip.duration = try await asset.load(.duration).seconds

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, fps, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                clip.displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
                clip.frameRate = fps
                if let format = formats.first {
                    (clip.isInterlaced, clip.detectedFieldOrder) = Deinterlacer.detect(format)
                }
            } else {
                clip.hasVideo = false
            }
            clip.hasAudio = !(try await asset.loadTracks(withMediaType: .audio).isEmpty)

            let values = try? clip.url.resourceValues(forKeys: [.fileSizeKey])
            clip.fileSize = Int64(values?.fileSize ?? 0)
            clip.isLoaded = true

            if clip.hasVideo {
                clip.thumbnails = await thumbnails(for: asset, duration: clip.duration)
            }
        } catch {
            clip.loadError = error.localizedDescription
        }
    }

    private static func thumbnails(for asset: AVURLAsset, duration: Double) async -> [Clip.Thumbnail] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        var result: [Clip.Thumbnail] = []
        for index in 0..<thumbnailCount {
            let seconds = duration * (Double(index) + 0.5) / Double(thumbnailCount)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                result.append(.init(time: seconds, image: image))
            }
        }
        return result
    }
}
