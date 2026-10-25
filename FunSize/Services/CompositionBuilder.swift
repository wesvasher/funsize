import AVFoundation

/// Joins timeline segments into one playable/exportable composition.
///
/// Clips with different sizes or rotations are scaled to fit the first
/// clip's frame, centered, with black bars where needed.
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

    static func build(_ segments: [Segment]) async throws -> Result {
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
        var frameRate: Float = 0

        for segment in segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            guard range.duration > .zero else { continue }

            let asset = AVURLAsset(url: segment.url)

            if let source = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, fps) = try await source.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                placements.append(Placement(at: cursor, naturalSize: size, transform: transform))
                frameRate = max(frameRate, fps)
                if renderSize == nil {
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    renderSize = CGSize(width: evenFloor(abs(rect.width)), height: evenFloor(abs(rect.height)))
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
                    fitTransform(natural: placement.naturalSize, preferred: placement.transform, into: renderSize),
                    at: placement.at
                )
            }
            let instruction = AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: .zero, duration: cursor)
            ))
            let fps = Int32(min(max(frameRate.rounded(), 24), 60))
            videoComposition = AVVideoComposition(configuration: .init(
                frameDuration: CMTime(value: 1, timescale: fps),
                instructions: [instruction],
                renderSize: renderSize
            ))
        } else {
            composition.removeTrack(videoTrack)
        }

        if audioTrack.segments.allSatisfy(\.isEmpty) {
            composition.removeTrack(audioTrack)
        }

        return Result(composition: composition, videoComposition: videoComposition, duration: cursor.seconds)
    }

    /// Applies the clip's rotation, then scales and centers it inside the render frame.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        var transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scale = min(render.width / rect.width, render.height / rect.height)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (render.width - rect.width * scale) / 2
        let offsetY = (render.height - rect.height * scale) / 2
        return transform.concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    private static func evenFloor(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
