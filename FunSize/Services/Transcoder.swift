import AVFoundation

/// Re-encodes a video with an export preset's settings: codec, quality or bit rate,
/// keyframes, picture size, frame rate, and audio format.
///
/// Frames come out of a video composition (so shape correction, effects, and timeline
/// layout all apply), then the writer scales them to the preset's size and compresses them.
nonisolated final class Transcoder: @unchecked Sendable {
    enum TranscodeError: LocalizedError {
        case nothingToExport
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: "This clip has nothing this preset can export (for example, no sound for an audio-only preset)."
            case .unsupported(let detail): detail
            case .failed(let detail): detail
            }
        }
    }

    private let asset: AVAsset
    private let videoComposition: AVVideoComposition?
    private let timeRange: CMTimeRange?
    private let preset: ExportPreset
    private let outputURL: URL

    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private let lock = NSLock()
    private var isCancelled = false

    init(asset: AVAsset, videoComposition: AVVideoComposition?, timeRange: CMTimeRange?, preset: ExportPreset, outputURL: URL) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.timeRange = timeRange
        self.preset = preset.normalized
        self.outputURL = outputURL
    }

    /// Runs the export. `progress` gets 0…1 as it goes.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await transcode(progress: progress)
        } onCancel: {
            cancel()
        }
    }

    private var pumps: [Pump] = []

    /// Stops the pumps. The reader is only cancelled after they're done, because
    /// reading samples while cancelling on another thread crashes.
    private func cancel() {
        let pumps = lock.withLock {
            isCancelled = true
            return self.pumps
        }
        pumps.forEach { $0.stop() }
    }

    private var wasCancelled: Bool { lock.withLock { isCancelled } }

    private func transcode(progress: @escaping @Sendable (Double) -> Void) async throws {
        let videoTracks = preset.video == nil ? [] : try await asset.loadTracks(withMediaType: .video)
        let audioTracks = preset.audio == nil ? [] : try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw TranscodeError.nothingToExport }

        let duration = try await asset.load(.duration)
        let range = (timeRange ?? CMTimeRange(start: .zero, duration: duration))
            .intersection(CMTimeRange(start: .zero, duration: duration))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: preset.container.fileType)
        writer.shouldOptimizeForNetworkUse = preset.optimizeForNetwork
        lock.withLock {
            self.reader = reader
            self.writer = writer
        }

        var pumps: [Pump] = []
        if let video = preset.video, !videoTracks.isEmpty {
            pumps.append(try await videoPump(video, tracks: videoTracks, reader: reader, writer: writer))
        }
        if let audio = preset.audio, !audioTracks.isEmpty {
            pumps.append(try await audioPump(audio, tracks: audioTracks, reader: reader, writer: writer))
        }
        if wasCancelled { throw CancellationError() }

        guard reader.startReading() else {
            throw TranscodeError.failed("Couldn't read the video: \(reader.error?.localizedDescription ?? "unknown error").")
        }
        guard writer.startWriting() else {
            throw TranscodeError.failed("Couldn't start writing: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: range.start)

        // Progress follows the video when there is some, otherwise the audio.
        let leader = pumps.first
        let allPumps = pumps
        lock.withLock { self.pumps = allPumps }
        if wasCancelled { allPumps.forEach { $0.stop() } }
        await withTaskGroup(of: Void.self) { group in
            for pump in allPumps {
                group.addTask {
                    await pump.run { time in
                        guard pump === leader, range.duration.seconds > 0 else { return }
                        progress(min(1, max(0, (time - range.start).seconds / range.duration.seconds)))
                    } isCancelled: { [self] in
                        wasCancelled
                    } onFailure: {
                        allPumps.forEach { $0.stop() }
                    }
                }
            }
        }

        if writer.status == .failed {
            reader.cancelReading()
            throw TranscodeError.failed("Couldn't write the file: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        if wasCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.failed("Couldn't read the video: \(reader.error?.localizedDescription ?? "unknown error").")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TranscodeError.failed("Couldn't finish the file: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        progress(1)
    }

    // MARK: Video

    private func videoPump(_ video: ExportPreset.Video, tracks: [AVAssetTrack], reader: AVAssetReader, writer: AVAssetWriter) async throws -> Pump {
        var composition: AVVideoComposition
        if let videoComposition {
            composition = videoComposition
        } else {
            composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        }
        if let fps = video.frameRate {
            composition = Self.copy(composition, frameDuration: ExportPreset.frameDuration(fps: fps))
        }

        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscodeError.failed("Couldn't read the video frames.") }
        reader.add(output)

        let size = video.outputSize(for: composition.renderSize)
        let fps = composition.frameDuration.seconds > 0 ? 1 / composition.frameDuration.seconds : 30
        var settings: [String: Any] = [
            AVVideoCodecKey: video.codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: video.scalingMode,
            AVVideoColorPropertiesKey: Self.colorProperties(height: size.height),
        ]
        if video.codec.hasCompressionSettings {
            var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())]
            switch video.rateControl {
            case .quality: compression[AVVideoQualityKey] = min(1, max(0, video.quality))
            case .bitRate: compression[AVVideoAverageBitRateKey] = Int(max(0.1, video.bitRateMbps) * 1_000_000)
            }
            if video.keyframeInterval > 0 {
                compression[AVVideoMaxKeyFrameIntervalKey] = video.keyframeInterval
            }
            if video.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw TranscodeError.unsupported("\(video.codec.title) can't be saved at \(Int(size.width))×\(Int(size.height)) in a \(preset.container.fileExtension.uppercased()) file.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Keep exact frame times (e.g. 1001/30000 s for 29.97) instead of rounding to the default time base.
        if let fps = video.frameRate {
            input.mediaTimeScale = max(ExportPreset.frameDuration(fps: fps).timescale, 600)
        } else if let track = tracks.first {
            input.mediaTimeScale = max(try await track.load(.naturalTimeScale), composition.frameDuration.timescale)
        }
        guard writer.canAdd(input) else { throw TranscodeError.unsupported("\(video.codec.title) can't go in a \(preset.container.fileExtension.uppercased()) file.") }
        writer.add(input)
        return Pump(output: output, input: input, label: "video")
    }

    /// Copies a composition with a different frame rate.
    static func copy(_ composition: AVVideoComposition, frameDuration: CMTime) -> AVVideoComposition {
        var config = AVVideoComposition.Configuration()
        config.customVideoCompositorClass = composition.customVideoCompositorClass
        config.instructions = composition.instructions
        config.renderSize = composition.renderSize
        config.renderScale = composition.renderScale
        config.colorPrimaries = composition.colorPrimaries
        config.colorTransferFunction = composition.colorTransferFunction
        config.colorYCbCrMatrix = composition.colorYCbCrMatrix
        // A new rate means evenly spaced frames, not the source's timing.
        config.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        config.frameDuration = frameDuration
        return AVVideoComposition(configuration: config)
    }

    /// Standard-definition sizes use SD color; anything bigger uses HD (Rec. 709).
    private static func colorProperties(height: CGFloat) -> [String: String] {
        height < 720
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ]
            : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
    }

    // MARK: Audio

    private func audioPump(_ audio: ExportPreset.Audio, tracks: [AVAssetTrack], reader: AVAssetReader, writer: AVAssetWriter) async throws -> Pump {
        let source = try await Self.audioFormat(of: tracks[0])
        var sampleRate = audio.sampleRate ?? source.sampleRate
        if audio.codec == .aac { sampleRate = min(sampleRate, 48_000) }
        let channels = audio.channels ?? min(max(source.channels, 1), 2)
        let layout = Self.layoutData(channels: channels)

        // Read as plain PCM in the shape the file needs; mixes multiple tracks together.
        let pcmBits = audio.codec == .pcm ? audio.bitDepth : 32
        let readSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layout,
            AVLinearPCMBitDepthKey: pcmBits,
            AVLinearPCMIsFloatKey: audio.codec != .pcm,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscodeError.failed("Couldn't read the sound.") }
        reader.add(output)

        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layout,
        ]
        switch audio.codec {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = audio.bitRateKbps * 1000
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = audio.bitDepth
        case .pcm:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = audio.bitDepth
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw TranscodeError.unsupported("\(audio.codec.title) audio can't be saved with these settings.")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscodeError.unsupported("\(audio.codec.title) audio can't go in a \(preset.container.fileExtension.uppercased()) file.") }
        writer.add(input)
        return Pump(output: output, input: input, label: "audio")
    }

    static func audioFormat(of track: AVAssetTrack) async throws -> (sampleRate: Double, channels: Int) {
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return (48_000, 2)
        }
        return (asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000, Int(asbd.mChannelsPerFrame))
    }

    private static func layoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}

/// Moves samples from one reader output to one writer input until the reader runs out.
nonisolated private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    private let queue: DispatchQueue
    // Only touched on `queue`.
    private var isDone = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String) {
        self.output = output
        self.input = input
        self.queue = DispatchQueue(label: "FunSize.export.\(label)")
    }

    /// `onFailure` runs if the writer stops accepting samples, so the other pumps can be stopped too.
    func run(onTime: @escaping @Sendable (CMTime) -> Void,
             isCancelled: @escaping @Sendable () -> Bool,
             onFailure: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while !isDone && input.isReadyForMoreMediaData {
                        if isCancelled() {
                            finish()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            finish()
                            return
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard input.append(sample) else {
                            finish()
                            onFailure()
                            return
                        }
                        if time.isNumeric { onTime(time) }
                    }
                }
            }
        }
    }

    /// Ends this pump early (another one failed).
    func stop() {
        queue.async { [self] in finish() }
    }

    /// Runs on `queue`.
    private func finish() {
        guard !isDone else { return }
        isDone = true
        input.markAsFinished()
        continuation?.resume()
        continuation = nil
    }
}
