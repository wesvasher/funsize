import AVFoundation
import CoreImage
import VideoToolbox

/// Super-resolution choices.
nonisolated enum UpscaleMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off
    /// Apple's low-latency scaler: 2×, no download, fast enough for live preview.
    case fast
    /// Apple's ML scaler: 4×, best quality, needs a one-time model download.
    case best

    var id: String { rawValue }

    var factor: Int {
        switch self {
        case .off: 1
        case .fast: 2
        case .best: 4
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .fast: "2× (Fast)"
        case .best: "4× (Best)"
        }
    }
}

/// Which effects to apply to a clip, in processing order.
nonisolated struct EnhanceSettings: Hashable, Sendable {
    /// Deinterlace (each field becomes a frame) when set.
    var fieldOrder: FieldOrder?
    /// Temporal noise reduction strength 0…1, or `nil` for off.
    var denoiseStrength: Float?
    var upscale: UpscaleMode = .off
    /// Sharpening amount 0…1; 0 is off.
    var sharpen: Float = 0

    var isActive: Bool {
        fieldOrder != nil || denoiseStrength != nil || upscale != .off || sharpen > 0
    }
}

nonisolated enum EnhanceError: LocalizedError {
    case unsupported(String)
    case modelNotReady
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "\(what) isn't supported for this video on this Mac."
        case .modelNotReady: "The 4× enhancement model isn't downloaded yet. Download it in the inspector's Effects section."
        case .failed(let message): message
        }
    }
}

/// Builds playable/exportable assets that run clips through the enhancement pipeline:
/// deinterlace → reduce noise → upscale → sharpen.
nonisolated enum Enhancer {
    /// Neighbor frames the noise filter compares against: one before, two after.
    static let neighborOffsets = [-1, 1, 2]

    // MARK: Capabilities

    static var canReduceNoise: Bool { VTTemporalNoiseFilterConfiguration.isSupported }

    static func canUpscale(_ mode: UpscaleMode, displaySize: CGSize) -> Bool {
        let width = Int(displaySize.width), height = Int(displaySize.height)
        switch mode {
        case .off:
            return true
        case .fast:
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
                && VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).contains(2)
        case .best:
            return VTSuperResolutionScalerConfiguration.isSupported
                && VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(4)
                && bestScalerConfiguration(width: width, height: height) != nil
        }
    }

    static func bestScalerConfiguration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .video,
            usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        )
    }

    /// Size of the finished picture.
    static func outputSize(displaySize: CGSize, upscale: UpscaleMode) -> CGSize {
        let even = evenSize(displaySize)
        return CGSize(width: even.width * CGFloat(upscale.factor), height: even.height * CGFloat(upscale.factor))
    }

    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    // MARK: Building

    /// An asset plus video composition that plays or exports `url` with `settings` applied.
    ///
    /// Noise reduction needs neighboring frames at every moment, including right after a seek, so the
    /// video is added several more times, each shifted by a frame. The compositor then receives the
    /// current frame and its neighbors together.
    static func makePlayable(url: URL, settings: EnhanceSettings) async throws -> (asset: AVAsset, videoComposition: AVVideoComposition?) {
        let source = AVURLAsset(url: url)
        guard settings.isActive else { return (source, nil) }
        try await checkModel(for: source, settings: settings)
        guard settings.denoiseStrength != nil else {
            return (source, try await videoComposition(for: source, settings: settings))
        }

        guard let video = try await source.loadTracks(withMediaType: .video).first else { return (source, nil) }
        let duration = try await source.load(.duration)
        let step = try await frameDuration(of: video)

        let composition = AVMutableComposition()
        guard let main = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EnhanceError.failed("Couldn't prepare the video for enhancement.")
        }
        try main.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)

        for audio in try await source.loadTracks(withMediaType: .audio) {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio, at: .zero)
        }

        // Track for offset k shows source frame (t + k·step) at time t.
        var neighbors: [Int: CMPersistentTrackID] = [:]
        for offset in neighborOffsets {
            let shift = CMTimeMultiply(step, multiplier: Int32(abs(offset)))
            guard shift < duration,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            if offset < 0 {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration - shift), of: video, at: shift)
            } else {
                try track.insertTimeRange(CMTimeRange(start: shift, duration: duration - shift), of: video, at: .zero)
            }
            neighbors[offset] = track.trackID
        }

        let geometry = try await VideoGeometry.load(video)
        let videoComposition = makeVideoComposition(
            settings: settings, duration: duration, sourceFrameDuration: step,
            mainTrack: main.trackID, neighborTracks: neighbors, displaySize: geometry.displaySize
        )
        return (composition, videoComposition)
    }

    /// A video composition for `asset` without neighbor tracks (no noise reduction).
    static func videoComposition(for asset: AVAsset, settings: EnhanceSettings) async throws -> AVVideoComposition? {
        guard settings.isActive, let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        try await checkModel(for: asset, settings: settings)
        var settings = settings
        settings.denoiseStrength = nil
        return makeVideoComposition(
            settings: settings,
            duration: try await asset.load(.duration),
            sourceFrameDuration: try await frameDuration(of: video),
            mainTrack: video.trackID, neighborTracks: [:],
            displaySize: try await VideoGeometry.load(video).displaySize
        )
    }

    /// 4× needs Apple's downloaded model. Say so up front instead of failing on every frame.
    private static func checkModel(for asset: AVAsset, settings: EnhanceSettings) async throws {
        guard settings.upscale == .best, let video = try await asset.loadTracks(withMediaType: .video).first else { return }
        let size = evenSize(try await VideoGeometry.load(video).displaySize)
        guard let config = bestScalerConfiguration(width: Int(size.width), height: Int(size.height)) else {
            throw EnhanceError.unsupported("4× enhancement")
        }
        guard config.configurationModelStatus == .ready else { throw EnhanceError.modelNotReady }
    }

    private static func makeVideoComposition(
        settings: EnhanceSettings, duration: CMTime, sourceFrameDuration: CMTime,
        mainTrack: CMPersistentTrackID, neighborTracks: [Int: CMPersistentTrackID], displaySize: CGSize
    ) -> AVVideoComposition {
        let display = evenSize(displaySize)
        let outputFrameDuration = settings.fieldOrder != nil
            ? CMTimeMultiplyByRatio(sourceFrameDuration, multiplier: 1, divisor: 2)
            : sourceFrameDuration
        let instruction = EnhanceInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            settings: settings, mainTrack: mainTrack, neighborTracks: neighborTracks,
            sourceFrameDuration: sourceFrameDuration, outputFrameDuration: outputFrameDuration,
            displaySize: display
        )
        return AVVideoComposition(configuration: .init(
            customVideoCompositorClass: EnhanceCompositor.self,
            frameDuration: outputFrameDuration,
            instructions: [instruction],
            renderSize: outputSize(displaySize: display, upscale: settings.upscale)
        ))
    }

    private static func frameDuration(of track: AVAssetTrack) async throws -> CMTime {
        let duration = try await track.load(.minFrameDuration)
        return duration.isNumeric && duration > .zero ? duration : CMTime(value: 1001, timescale: 30000)
    }
}

/// Settings and track layout for one enhanced clip.
nonisolated final class EnhanceInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let settings: EnhanceSettings
    let mainTrack: CMPersistentTrackID
    /// Frame offset (−1, +1, +2) → track showing that neighbor.
    let neighborTracks: [Int: CMPersistentTrackID]
    let sourceFrameDuration: CMTime
    let outputFrameDuration: CMTime
    let displaySize: CGSize

    init(timeRange: CMTimeRange, settings: EnhanceSettings, mainTrack: CMPersistentTrackID,
         neighborTracks: [Int: CMPersistentTrackID], sourceFrameDuration: CMTime,
         outputFrameDuration: CMTime, displaySize: CGSize) {
        self.timeRange = timeRange
        self.settings = settings
        self.mainTrack = mainTrack
        self.neighborTracks = neighborTracks
        self.sourceFrameDuration = sourceFrameDuration
        self.outputFrameDuration = outputFrameDuration
        self.displaySize = displaySize
        self.requiredSourceTrackIDs = ([mainTrack] + neighborTracks.values.sorted()).map { NSNumber(value: $0) }
    }
}

/// Hands each frame (and its neighbors) to the pipeline on a private queue.
nonisolated final class EnhanceCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = EnhanceCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = EnhanceCompositor.bgra

    private let queue = DispatchQueue(label: "FunSize.Enhance")
    private var pipeline: EnhancePipeline?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { self.render(request) }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard
            let instruction = request.videoCompositionInstruction as? EnhanceInstruction,
            let source = request.sourceFrame(byTrackID: instruction.mainTrack),
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: EnhanceError.failed("Couldn't read a video frame to enhance."))
            return
        }
        do {
            if pipeline?.instruction !== instruction {
                pipeline = try EnhancePipeline(instruction: instruction)
            }
            var neighbors: [Int: CVPixelBuffer] = [:]
            for (offset, track) in instruction.neighborTracks {
                neighbors[offset] = request.sourceFrame(byTrackID: track)
            }
            try pipeline?.render(source: source, neighbors: neighbors, time: request.compositionTime, into: output)
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }
}

/// Runs the effects for one clip. Keeps state between frames (scaler history, buffer pools).
/// Not thread-safe: the compositor uses it from one queue.
nonisolated final class EnhancePipeline {
    let instruction: EnhanceInstruction
    private let settings: EnhanceSettings
    private let width: Int
    private let height: Int

    private var transfer: VTPixelTransferSession
    private var fieldPool: CVPixelBufferPool?
    private var lastTime: CMTime?

    /// Identifies a picture by source frame number and field (nil = whole frame).
    private struct PictureKey: Hashable {
        let frame: Int
        let field: Int?
    }
    /// Pictures already built for nearby frames. Each output frame reuses most of its neighbors'.
    private var fieldCache: [PictureKey: CVPixelBuffer] = [:]
    private var denoiseInputCache: [PictureKey: CVPixelBuffer] = [:]
    private var currentFrameIndex = 0

    private var denoiser: VTFrameProcessor?
    private var denoiseSourcePool: CVPixelBufferPool?
    private var denoiseOutputPool: CVPixelBufferPool?

    private var scaler: VTFrameProcessor?
    private var scalerSourcePool: CVPixelBufferPool?
    private var scalerOutputPool: CVPixelBufferPool?
    private var previousScalerSource: VTFrameProcessorFrame?
    private var previousScalerOutput: VTFrameProcessorFrame?

    private var sharpenPool: CVPixelBufferPool?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    init(instruction: EnhanceInstruction) throws {
        self.instruction = instruction
        settings = instruction.settings
        width = Int(instruction.displaySize.width)
        height = Int(instruction.displaySize.height)

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let session else { throw EnhanceError.failed("Couldn't start video processing.") }
        transfer = session

        if settings.denoiseStrength != nil {
            guard let config = VTTemporalNoiseFilterConfiguration(
                frameWidth: width, frameHeight: height,
                sourcePixelFormat: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
            ) else { throw EnhanceError.unsupported("Noise reduction") }
            let processor = VTFrameProcessor()
            try processor.startSession(configuration: config)
            denoiser = processor
            denoiseSourcePool = try Self.pool(config.sourcePixelBufferAttributes)
            denoiseOutputPool = try Self.pool(config.destinationPixelBufferAttributes)
        }

        switch settings.upscale {
        case .off:
            break
        case .fast:
            let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 2)
            let processor = VTFrameProcessor()
            try processor.startSession(configuration: config)
            scaler = processor
            scalerSourcePool = try Self.pool(config.sourcePixelBufferAttributes)
            scalerOutputPool = try Self.pool(config.destinationPixelBufferAttributes)
        case .best:
            guard let config = Enhancer.bestScalerConfiguration(width: width, height: height) else {
                throw EnhanceError.unsupported("4× enhancement")
            }
            guard config.configurationModelStatus == .ready else { throw EnhanceError.modelNotReady }
            let processor = VTFrameProcessor()
            try processor.startSession(configuration: config)
            scaler = processor
            scalerSourcePool = try Self.pool(config.sourcePixelBufferAttributes)
            scalerOutputPool = try Self.pool(config.destinationPixelBufferAttributes)
        }
    }

    deinit {
        denoiser?.endSession()
        scaler?.endSession()
    }

    // MARK: Per frame

    func render(source: CVPixelBuffer, neighbors: [Int: CVPixelBuffer], time: CMTime, into output: CVPixelBuffer) throws {
        let step = instruction.outputFrameDuration
        let isContinuous = lastTime.map { abs((time - $0 - step).seconds) < step.seconds / 2 } ?? false
        lastTime = time
        if !isContinuous {
            previousScalerSource = nil
            previousScalerOutput = nil
            fieldCache.removeAll()
            denoiseInputCache.removeAll()
        }
        currentFrameIndex = Int((time.seconds / instruction.sourceFrameDuration.seconds + 0.25).rounded(.down))
        // Keep only pictures near the current frame.
        fieldCache = fieldCache.filter { abs($0.key.frame - currentFrameIndex) <= 2 }
        denoiseInputCache = denoiseInputCache.filter { abs($0.key.frame - currentFrameIndex) <= 2 }

        // Which field of the current source frame (0 = first in time) this output frame shows.
        var field: Int?
        if settings.fieldOrder != nil {
            let fieldDuration = instruction.sourceFrameDuration.seconds / 2
            field = Int((time.seconds / fieldDuration).rounded()) % 2
        }
        var frames = neighbors
        frames[0] = source

        var picture = try picture(frames, frame: 0, field: field)
        if let strength = settings.denoiseStrength {
            picture = try reduceNoise(picture, frames: frames, field: field, strength: strength, time: time, isContinuous: isContinuous)
        }
        if scaler != nil {
            picture = try upscale(picture, time: time, isContinuous: isContinuous)
        }
        if settings.sharpen > 0 {
            try sharpen(picture, into: output)
        } else {
            try copy(picture, into: output)
        }
    }

    /// A source frame, or one field of it made into a full frame (stored size, BGRA).
    private func picture(_ frames: [Int: CVPixelBuffer], frame offset: Int, field: Int?) throws -> CVPixelBuffer {
        guard let frame = frames[offset] else { throw EnhanceError.failed("Missing video frame.") }
        guard let field, let order = settings.fieldOrder else { return frame }
        let key = PictureKey(frame: currentFrameIndex + offset, field: field)
        if let cached = fieldCache[key] { return cached }
        if fieldPool == nil {
            fieldPool = try Self.pool(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame), format: kCVPixelFormatType_32BGRA)
        }
        let output = try Self.buffer(from: fieldPool)
        let useTopField = (order == .topFirst) == (field == 0)
        Deinterlacer.bob(frame, into: output, keepOddRows: !useTopField)
        fieldCache[key] = output
        return output
    }

    /// A picture converted for the noise filter, reused across neighboring output frames.
    private func denoiseInput(_ frames: [Int: CVPixelBuffer], frame offset: Int, field: Int?) throws -> CVPixelBuffer {
        let key = PictureKey(frame: currentFrameIndex + offset, field: field)
        if let cached = denoiseInputCache[key] { return cached }
        let converted = try convert(try picture(frames, frame: offset, field: field), pool: denoiseSourcePool)
        denoiseInputCache[key] = converted
        return converted
    }

    // MARK: Noise reduction

    private func reduceNoise(_ picture: CVPixelBuffer, frames: [Int: CVPixelBuffer], field: Int?,
                             strength: Float, time: CMTime, isContinuous: Bool) throws -> CVPixelBuffer {
        guard let denoiser else { return picture }
        let step = instruction.outputFrameDuration

        // Neighbors in output order: 1 before, 2 after. With deinterlacing these are fields.
        let before: [(frame: Int, field: Int?)]
        let after: [(frame: Int, field: Int?)]
        if let field {
            before = [field == 1 ? (0, 0) : (-1, 1)]
            after = [field == 0 ? (0, 1) : (1, 0), (1, field)]
        } else {
            before = [(-1, nil)]
            after = [(1, nil), (2, nil)]
        }

        func reference(_ spec: (frame: Int, field: Int?), at index: Int) throws -> VTFrameProcessorFrame? {
            guard frames[spec.frame] != nil else { return nil }
            let converted = try denoiseInput(frames, frame: spec.frame, field: spec.field)
            return VTFrameProcessorFrame(buffer: converted, presentationTimeStamp: time + CMTimeMultiply(step, multiplier: Int32(index)))
        }
        let previous = try before.compactMap { try reference($0, at: -1) }
        let next = try after.enumerated().compactMap { try reference($0.element, at: $0.offset + 1) }
        guard !previous.isEmpty || !next.isEmpty else { return picture }  // single-frame clip

        let source = try denoiseInput(frames, frame: 0, field: field)
        let destination = try Self.buffer(from: denoiseOutputPool)
        guard
            let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
            let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time),
            let parameters = VTTemporalNoiseFilterParameters(
                sourceFrame: sourceFrame, nextFrames: next, previousFrames: previous,
                destinationFrame: destinationFrame, filterStrength: strength, hasDiscontinuity: !isContinuous
            )
        else { throw EnhanceError.failed("Couldn't set up noise reduction.") }
        try Self.run(denoiser, parameters)
        return destination
    }

    // MARK: Upscaling

    private func upscale(_ picture: CVPixelBuffer, time: CMTime, isContinuous: Bool) throws -> CVPixelBuffer {
        guard let scaler else { return picture }
        let source = try convert(picture, pool: scalerSourcePool)
        let destination = try Self.buffer(from: scalerOutputPool)
        guard
            let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
            let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time)
        else { throw EnhanceError.failed("Couldn't set up enhancement.") }

        let parameters: any VTFrameProcessorParameters
        if settings.upscale == .best {
            guard let best = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame,
                previousFrame: isContinuous ? previousScalerSource : nil,
                previousOutputFrame: isContinuous ? previousScalerOutput : nil,
                opticalFlow: nil,
                submissionMode: isContinuous ? .sequential : .random,
                destinationFrame: destinationFrame
            ) else { throw EnhanceError.failed("Couldn't set up 4× enhancement.") }
            parameters = best
        } else {
            parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        }
        try Self.run(scaler, parameters)
        previousScalerSource = sourceFrame
        previousScalerOutput = destinationFrame
        return destination
    }

    // MARK: Sharpening and output

    private func sharpen(_ picture: CVPixelBuffer, into output: CVPixelBuffer) throws {
        if sharpenPool == nil {
            sharpenPool = try Self.pool(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output), format: kCVPixelFormatType_32BGRA)
        }
        let scratch = try Self.buffer(from: sharpenPool)
        try copy(picture, into: scratch)

        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(cvPixelBuffer: scratch, options: [.colorSpace: color])
        let filter = CIFilter(name: "CISharpenLuminance")!
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(Double(settings.sharpen) * 1.5, forKey: kCIInputSharpnessKey)
        filter.setValue(Double(settings.upscale.factor), forKey: kCIInputRadiusKey)
        guard let sharpened = filter.outputImage?.cropped(to: image.extent) else { throw EnhanceError.failed("Couldn't sharpen.") }
        ciContext.render(sharpened, to: output, bounds: image.extent, colorSpace: color)
    }

    /// Converts format and scales to fit the destination (this also corrects the picture shape).
    private func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
        guard status == noErr else { throw EnhanceError.failed("Couldn't convert a video frame (\(status)).") }
    }

    private func convert(_ source: CVPixelBuffer, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        let destination = try Self.buffer(from: pool)
        try copy(source, into: destination)
        return destination
    }

    // MARK: Helpers

    private static func run(_ processor: VTFrameProcessor, _ parameters: any VTFrameProcessorParameters) throws {
        final class Result: @unchecked Sendable { var error: Error? }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        processor.process(parameters: parameters) { _, error in
            result.error = error
            done.signal()
        }
        done.wait()
        if let error = result.error { throw error }
    }

    private static func pool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard let pool else { throw EnhanceError.failed("Couldn't allocate video memory.") }
        return pool
    }

    private static func pool(width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        try pool([
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
    }

    private static func buffer(from pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer else { throw EnhanceError.failed("Couldn't allocate video memory.") }
        return buffer
    }
}
