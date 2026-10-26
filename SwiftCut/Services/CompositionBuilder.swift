import AVFoundation

/// Joins timeline segments into one playable/exportable composition.
///
/// The frame size and rate come from the timeline settings; on Automatic, the size is the
/// first clip's and the rate follows the fastest clip. Clips of a different size or rotation
/// are scaled to fit (with black bars) or fill (cropping) the frame, centered.
enum CompositionBuilder {
    struct Segment {
        let url: URL
        let start: Double
        let end: Double
    }

    struct Result {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        let duration: Double
    }

    enum BuildError: LocalizedError {
        case empty
        case trackCreationFailed

        var errorDescription: String? {
            switch self {
            case .empty: "The timeline is empty."
            case .trackCreationFailed: "Couldn't create the combined video."
            }
        }
    }

    static func build(_ segments: [Segment], settings: TimelineSettings = TimelineSettings()) async throws -> Result {
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.trackCreationFailed }

        struct Placement {
            let at: CMTime
            let naturalSize: CGSize
            let transform: CGAffineTransform
        }

        var placements: [Placement] = []
        var cursor = CMTime.zero
        var renderSize: CGSize?
        var frameDuration: CMTime?

        for segment in segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            guard range.duration > .zero else { continue }

            let asset = AVURLAsset(url: segment.url)

            if let source = try await asset.loadTracks(withMediaType: .video).first {
                let minFrame = try await source.load(.minFrameDuration)
                let geometry = try await VideoGeometry.load(source)
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                placements.append(Placement(at: cursor, naturalSize: geometry.encodedSize, transform: geometry.transform))
                // Use the fastest clip's exact timing (29.97 stays 29.97).
                if minFrame.isNumeric, minFrame > .zero, frameDuration.map({ minFrame < $0 }) ?? true {
                    frameDuration = minFrame
                }
                if renderSize == nil {
                    renderSize = settings.renderSize(firstClip: geometry.displaySize)
                }
            } else {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }

            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: source, at: cursor)
            } else {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }

            cursor = cursor + range.duration
        }

        guard cursor > .zero else { throw BuildError.empty }

        var videoComposition: AVVideoComposition?
        if let renderSize, !placements.isEmpty {
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
            for placement in placements {
                layer.setTransform(
                    fitTransform(natural: placement.naturalSize, preferred: placement.transform, into: renderSize,
                                 fill: settings.fit == .fill),
                    at: placement.at
                )
            }
            let instruction = AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: .zero, duration: cursor)
            ))
            let shortest = CMTime(value: 1, timescale: 120), longest = CMTime(value: 1, timescale: 10)
            let duration = settings.frameRate.frameDuration
                ?? min(max(frameDuration ?? CMTime(value: 1, timescale: 30), shortest), longest)
            var config = AVVideoComposition.Configuration(
                frameDuration: duration,
                instructions: [instruction],
                renderSize: renderSize
            )
            if settings.frameRate == .automatic {
                // Output a frame for each source frame, at its exact time. Without this the
                // compositor drops a frame near the start and drifts on 29.97 video.
                config.sourceTrackIDForFrameTiming = videoTrack.trackID
            }
            videoComposition = AVVideoComposition(configuration: config)
        } else {
            composition.removeTrack(videoTrack)
        }

        if audioTrack.segments.allSatisfy(\.isEmpty) {
            composition.removeTrack(audioTrack)
        }

        return Result(composition: composition, videoComposition: videoComposition, duration: cursor.seconds)
    }

    /// Applies the clip's shape correction and rotation, then scales and centers it inside the render frame:
    /// all of it showing (`fill` false), or covering the frame with its edges cut off (`fill` true).
    /// `natural` is the stored pixel size of the source frames.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into render: CGSize,
                             fill: Bool = false) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        var transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scales = (render.width / rect.width, render.height / rect.height)
        let scale = fill ? max(scales.0, scales.1) : min(scales.0, scales.1)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (render.width - rect.width * scale) / 2
        let offsetY = (render.height - rect.height * scale) / 2
        return transform.concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }
}
