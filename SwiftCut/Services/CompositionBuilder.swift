import AVFoundation
import CoreImage

/// Joins timeline segments into one playable/exportable composition.
///
/// Each segment carries its clip's effects and color (deinterlace, noise reduction, upscaling,
/// LUT, look, grade, sharpening), applied by the same pipeline as the clip viewer, so the
/// timeline matches what the clip viewer shows.
///
/// The frame size and rate come from the timeline settings; on Automatic, the size is the first
/// clip's (after upscaling) and the rate follows the fastest clip. Clips of a different size or
/// rotation are scaled to fit (with black bars) or fill (cropping) the frame, centered.
enum CompositionBuilder {
    struct Segment {
        let url: URL
        let start: Double
        let end: Double
        /// The clip's effects and color. Untouched by default.
        var settings = EnhanceSettings()
    }

    struct Result {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        /// Turns clips up or down (see `TimelineAudio`), when asked for.
        var audioMix: AVAudioMix?
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

    /// `audio` sets each stretch's volume; without it the sound plays as recorded.
    static func build(_ segments: [Segment], settings: TimelineSettings = TimelineSettings(),
                      audio: TimelineAudio? = nil) async throws -> Result {
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.trackCreationFailed }

        /// One segment's video, before the frame size is known.
        struct Placement {
            let range: CMTimeRange
            let sourceStart: CMTime
            /// Size of the picture the renderer starts from: stored pixels, or the effects' output.
            let pictureSize: CGSize
            let transform: CGAffineTransform
            let enhance: EnhanceInstruction?
            let neighborTracks: [CMPersistentTrackID]
            let hasVideo: Bool
        }

        var placements: [Placement] = []
        var cursor = CMTime.zero
        var firstPictureSize: CGSize?
        var frameDuration: CMTime?
        var anyDeinterlaced = false
        // Noise reduction reads neighboring frames from extra tracks, shared by all segments.
        var neighborTracks: [Int: AVMutableCompositionTrack] = [:]

        for segment in segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            guard range.duration > .zero else { continue }
            let timelineRange = CMTimeRange(start: cursor, duration: range.duration)
            let asset = AVURLAsset(url: segment.url)

            if let source = try await asset.loadTracks(withMediaType: .video).first {
                let step = try await sourceFrameDuration(of: source)
                let geometry = try await VideoGeometry.load(source)
                try videoTrack.insertTimeRange(range, of: source, at: cursor)

                let effects = segment.settings
                var enhance: EnhanceInstruction?
                var usedNeighbors: [CMPersistentTrackID] = []
                var pictureSize = geometry.encodedSize
                var transform = geometry.transform
                var outputStep = step

                if effects.isActive {
                    try await Enhancer.checkModel(for: asset, settings: effects)
                    let display = Enhancer.evenSize(geometry.displaySize)
                    outputStep = effects.fieldOrder != nil ? CMTimeMultiplyByRatio(step, multiplier: 1, divisor: 2) : step
                    anyDeinterlaced = anyDeinterlaced || effects.fieldOrder != nil

                    var neighbors: [Int: CMPersistentTrackID] = [:]
                    if effects.denoiseStrength != nil {
                        let sourceDuration = try await asset.load(.duration)
                        for offset in Enhancer.neighborOffsets {
                            if neighborTracks[offset] == nil {
                                neighborTracks[offset] = composition.addMutableTrack(withMediaType: .video,
                                                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
                            }
                            guard let track = neighborTracks[offset] else { continue }
                            // At timeline time t, this track shows the source frame `offset` frames from t's.
                            let shift = CMTimeMultiply(step, multiplier: Int32(offset))
                            let wanted = CMTimeRange(start: range.start + shift, duration: range.duration)
                            let available = wanted.intersection(CMTimeRange(start: .zero, duration: sourceDuration))
                            guard available.duration > .zero else { continue }
                            let at = cursor + (available.start - wanted.start)
                            pad(track, to: at)
                            try track.insertTimeRange(available, of: source, at: at)
                            neighbors[offset] = track.trackID
                            usedNeighbors.append(track.trackID)
                        }
                    }
                    enhance = EnhanceInstruction(
                        timeRange: timelineRange, settings: effects, mainTrack: videoTrack.trackID,
                        neighborTracks: neighbors, sourceFrameDuration: step, outputFrameDuration: outputStep,
                        displaySize: display, color: effects.colorLook.map { LiveColor($0) }
                    )
                    // The effects output the corrected picture (shape fixed, maybe upscaled), upright.
                    pictureSize = Enhancer.outputSize(displaySize: display, upscale: effects.upscale)
                    transform = .identity
                }

                if firstPictureSize == nil {
                    let shown = CGRect(origin: .zero, size: pictureSize).applying(transform)
                    firstPictureSize = CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())
                }
                // Use the fastest clip's exact timing (29.97 stays 29.97; deinterlaced clips count double).
                if frameDuration.map({ outputStep < $0 }) ?? true {
                    frameDuration = outputStep
                }
                placements.append(Placement(range: timelineRange, sourceStart: range.start, pictureSize: pictureSize,
                                            transform: transform, enhance: enhance, neighborTracks: usedNeighbors,
                                            hasVideo: true))
            } else {
                videoTrack.insertEmptyTimeRange(timelineRange)
                placements.append(Placement(range: timelineRange, sourceStart: range.start, pictureSize: .zero,
                                            transform: .identity, enhance: nil, neighborTracks: [], hasVideo: false))
            }

            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: source, at: cursor)
            } else {
                audioTrack.insertEmptyTimeRange(timelineRange)
            }

            cursor = cursor + range.duration
        }

        guard cursor > .zero else { throw BuildError.empty }

        var videoComposition: AVVideoComposition?
        if let firstPictureSize {
            let renderSize = settings.renderSize(firstClip: firstPictureSize)
            let instructions = placements.map { placement in
                TimelineInstruction(
                    timeRange: placement.range, mainTrack: videoTrack.trackID, hasVideo: placement.hasVideo,
                    sourceStart: placement.sourceStart, pictureSize: placement.pictureSize,
                    placement: placement.hasVideo
                        ? fitTransform(natural: placement.pictureSize, preferred: placement.transform,
                                       into: renderSize, fill: settings.fit == .fill)
                        : .identity,
                    renderSize: renderSize, enhance: placement.enhance, neighborTracks: placement.neighborTracks
                )
            }
            let shortest = CMTime(value: 1, timescale: 120), longest = CMTime(value: 1, timescale: 10)
            let duration = settings.frameRate.frameDuration
                ?? min(max(frameDuration ?? CMTime(value: 1, timescale: 30), shortest), longest)
            var config = AVVideoComposition.Configuration(
                customVideoCompositorClass: TimelineCompositor.self,
                frameDuration: duration,
                instructions: instructions,
                renderSize: renderSize
            )
            if settings.frameRate == .automatic, !anyDeinterlaced {
                // Output a frame for each source frame, at its exact time. Without this the
                // compositor drops a frame near the start and drifts on 29.97 video.
                // (Deinterlaced clips make two frames from each source frame, so not then.)
                config.sourceTrackIDForFrameTiming = videoTrack.trackID
            }
            videoComposition = AVVideoComposition(configuration: config)
        } else {
            composition.removeTrack(videoTrack)
        }

        var audioMix: AVAudioMix?
        if audioTrack.segments.allSatisfy(\.isEmpty) {
            composition.removeTrack(audioTrack)
        } else if let audio {
            audioMix = audio.audioMix(for: audioTrack)
        }

        return Result(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                      duration: cursor.seconds)
    }

    /// Fills a track with nothing up to `time`, so the next insert lands there.
    private static func pad(_ track: AVMutableCompositionTrack, to time: CMTime) {
        let end = track.timeRange.end
        let start = end.isNumeric ? end : .zero
        if time > start {
            track.insertEmptyTimeRange(CMTimeRange(start: start, end: time))
        }
    }

    private static func sourceFrameDuration(of track: AVAssetTrack) async throws -> CMTime {
        let duration = try await track.load(.minFrameDuration)
        return duration.isNumeric && duration > .zero ? duration : CMTime(value: 1001, timescale: 30000)
    }

    /// Applies the clip's shape correction and rotation, then scales and centers it inside the render frame:
    /// all of it showing (`fill` false), or covering the frame with its edges cut off (`fill` true).
    /// `natural` is the pixel size of the picture going in.
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

/// One timeline segment: where its frames come from, its effects, and where it goes in the frame.
nonisolated final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let mainTrack: CMPersistentTrackID
    /// `false` for audio-only segments, which show black.
    let hasVideo: Bool
    /// The source time at the start of `timeRange`.
    let sourceStart: CMTime
    /// Size of the picture before placement (stored pixels, or the effects' output).
    let pictureSize: CGSize
    /// Maps the picture into the render frame (top-left origin, like video transforms).
    let placement: CGAffineTransform
    let renderSize: CGSize
    /// The clip's effects, or `nil` when it has none.
    let enhance: EnhanceInstruction?

    init(timeRange: CMTimeRange, mainTrack: CMPersistentTrackID, hasVideo: Bool, sourceStart: CMTime,
         pictureSize: CGSize, placement: CGAffineTransform, renderSize: CGSize,
         enhance: EnhanceInstruction?, neighborTracks: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.mainTrack = mainTrack
        self.hasVideo = hasVideo
        self.sourceStart = sourceStart
        self.pictureSize = pictureSize
        self.placement = placement
        self.renderSize = renderSize
        self.enhance = enhance
        self.requiredSourceTrackIDs = hasVideo ? ([mainTrack] + neighborTracks).map { NSNumber(value: $0) } : []
    }
}

/// Draws each timeline frame: runs the clip's effects (if any), then places the picture in the
/// timeline's frame over black.
nonisolated final class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = TimelineCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = TimelineCompositor.bgra

    private let queue = DispatchQueue(label: "SwiftCut.Timeline")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Effects pipelines for recently shown segments (they keep state between frames).
    private var pipelines: [ObjectIdentifier: (pipeline: EnhancePipeline, pool: CVPixelBufferPool)] = [:]
    private var recent: [ObjectIdentifier] = []

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { self.render(request) }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: EnhanceError.failed("Couldn't draw a timeline frame."))
            return
        }
        let frame = CGRect(origin: .zero, size: instruction.renderSize)
        var image = CIImage(color: .black).cropped(to: frame)
        do {
            if instruction.hasVideo, let source = request.sourceFrame(byTrackID: instruction.mainTrack) {
                var picture = source
                if let enhance = instruction.enhance {
                    let entry = try pipeline(for: enhance, size: instruction.pictureSize)
                    let processed = try Self.buffer(from: entry.pool)
                    var neighbors: [Int: CVPixelBuffer] = [:]
                    for (offset, track) in enhance.neighborTracks {
                        neighbors[offset] = request.sourceFrame(byTrackID: track)
                    }
                    // The effects work in source time (frame numbers, field order).
                    let sourceTime = request.compositionTime - instruction.timeRange.start + instruction.sourceStart
                    try entry.pipeline.render(source: source, neighbors: neighbors, time: sourceTime, into: processed)
                    picture = processed
                }
                let height = CGFloat(CVPixelBufferGetHeight(picture))
                let placed = CIImage(cvPixelBuffer: picture, options: [.colorSpace: color])
                    .transformed(by: Self.coreImageTransform(instruction.placement, inputHeight: height,
                                                             outputHeight: instruction.renderSize.height))
                image = placed.cropped(to: frame).composited(over: image)
            }
            context.render(image, to: output, bounds: frame, colorSpace: color)
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }

    private func pipeline(for instruction: EnhanceInstruction, size: CGSize) throws -> (pipeline: EnhancePipeline, pool: CVPixelBufferPool) {
        let key = ObjectIdentifier(instruction)
        recent.removeAll { $0 == key }
        recent.append(key)
        if let entry = pipelines[key] { return entry }
        // Keep a few, so going back and forth between neighboring clips doesn't restart them.
        while recent.count > 3 {
            pipelines[recent.removeFirst()] = nil
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary, &pool)
        guard let pool else { throw EnhanceError.failed("Couldn't allocate video memory.") }
        let entry = (pipeline: try EnhancePipeline(instruction: instruction), pool: pool)
        pipelines[key] = entry
        return entry
    }

    private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw EnhanceError.failed("Couldn't allocate video memory.") }
        return buffer
    }

    /// Video transforms measure from the top left; Core Image from the bottom left.
    static func coreImageTransform(_ transform: CGAffineTransform, inputHeight: CGFloat, outputHeight: CGFloat) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: inputHeight)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outputHeight)
        return flipIn.concatenating(transform).concatenating(flipOut)
    }
}
