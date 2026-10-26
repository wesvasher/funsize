import AVFoundation
import MediaToolbox

/// The timeline's sound: turns each clip up or down (to even out loudness) and measures the
/// level as it plays, for the meters.
///
/// The volume changes run in an audio tap rather than AVAudioMix's volume, which can't go
/// above 1 (quiet clips need turning up). The gains can change while the timeline plays, so
/// moving a slider doesn't rebuild the player.
nonisolated final class TimelineAudio: @unchecked Sendable {
    /// A stretch of the timeline and how much to turn it up or down.
    struct Span: Hashable, Sendable {
        var start: Double
        var end: Double
        var gainDB: Double
    }

    /// The sound playing now, after the gains.
    struct Level: Sendable {
        /// Timeline seconds.
        var time: Double
        /// Momentary loudness (the last 400 ms) in LUFS.
        var momentary: Double
        /// Each channel's loudest sample in the last 100 ms, in dB.
        var peaks: [Double]
        /// `ProcessInfo.systemUptime` when it was measured.
        var measuredAt: TimeInterval
    }

    /// The timeline's sound measured ahead of time, so the meters can follow scrubbing
    /// (a paused player plays no sound to measure). Levels are before the gains.
    struct Envelope: Sendable {
        /// Seconds per step.
        static let step = 0.1
        /// Each step's loudest sample per channel (0…1).
        var peaks: [[Float]]
        /// Each step's K-weighted mean square, summed over channels (for momentary loudness).
        var power: [Double]
    }

    private let lock = NSLock()
    private var _spans: [Span]
    private var _level: Level?
    private var _envelope: Envelope?
    private var scrub: (time: Double, at: TimeInterval)?

    init(spans: [Span] = []) {
        _spans = spans
    }

    var spans: [Span] {
        get { lock.withLock { _spans } }
        set { lock.withLock { _spans = newValue } }
    }

    var envelope: Envelope? {
        get { lock.withLock { _envelope } }
        set { lock.withLock { _envelope = newValue } }
    }

    /// The latest level: what's playing, or where the playhead was just dragged.
    /// `nil` once nothing has played or moved for a moment.
    var level: Level? {
        let now = ProcessInfo.processInfo.systemUptime
        let (live, scrub) = lock.withLock { (_level, self.scrub) }
        if let live, now - live.measuredAt < 0.3 { return live }
        if let scrub, now - scrub.at < 0.4 { return level(at: scrub.time, measuredAt: scrub.at) }
        return nil
    }

    /// Call while dragging the playhead, so the meters show the sound there.
    func noteScrub(at time: Double) {
        lock.withLock { scrub = (time, ProcessInfo.processInfo.systemUptime) }
    }

    /// The level at `time` from the envelope, after the gains.
    func level(at time: Double, measuredAt: TimeInterval) -> Level? {
        let (envelope, spans) = lock.withLock { (_envelope, _spans) }
        guard let envelope, time >= 0 else { return nil }
        let index = Int(time / Envelope.step)
        guard index < envelope.power.count else { return nil }
        func gain(_ index: Int) -> Double {
            let at = (Double(index) + 0.5) * Envelope.step
            return spans.first { at >= $0.start && at < $0.end }?.gainDB ?? 0
        }
        // Momentary loudness covers the last 400 ms, as while playing.
        let window = max(0, index - 3)...index
        let power = window.map { envelope.power[$0] * pow(10, gain($0) / 10) }.reduce(0, +) / Double(window.count)
        return Level(time: time, momentary: Loudness.lufs(meanSquare: power),
                     peaks: envelope.peaks[index].map { Loudness.decibels(Double($0)) + gain(index) },
                     measuredAt: measuredAt)
    }

    /// Measures `asset`'s sound in steps, for `envelope`.
    static func envelope(of asset: AVAsset) async throws -> Envelope? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let stepLength = Int(48_000 * Envelope.step)
        var filters = [KWeighting(sampleRate: 48_000), KWeighting(sampleRate: 48_000)]
        var envelope = Envelope(peaks: [], power: [])
        var peaks: [Float] = [0, 0]
        var sum = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                var index = 0
                while index + 1 < length / 4 {
                    for channel in 0..<2 {
                        let sample = samples[index + channel]
                        peaks[channel] = max(peaks[channel], abs(sample))
                        let weighted = filters[channel].process(Double(sample))
                        sum += weighted * weighted
                    }
                    count += 1
                    if count == stepLength {
                        envelope.peaks.append(peaks)
                        envelope.power.append(sum / Double(stepLength))
                        peaks = [0, 0]
                        sum = 0
                        count = 0
                    }
                    index += 2
                }
            }
        }
        if count > 0 {
            envelope.peaks.append(peaks)
            envelope.power.append(sum / Double(count))
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return envelope
    }

    func publish(_ level: Level) {
        lock.withLock { _level = level }
    }

    /// An audio mix that applies the gains to `track` (the timeline's sound track).
    func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = TapContext(owner: self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee), start: range.start)
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(context).release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

/// One tap's state. Only the audio thread touches it, apart from `prepare`.
private nonisolated final class TapContext {
    private weak var owner: TimelineAudio?
    private var sampleRate = 48_000.0
    private var isFloat = false
    private var filters: [KWeighting] = []
    /// Where the next buffer should start, to notice seeking.
    private var expected = -1.0
    private var gain = 1.0
    private var smoothing = 0.0
    // Momentary loudness: the last four 100 ms steps.
    private var steps: [Double] = []
    private var stepSum = 0.0
    private var stepCount = 0
    private var stepLength = 4_800
    private var stepPeaks: [Float] = []

    init(owner: TimelineAudio) {
        self.owner = owner
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let channels = Int(max(1, format.mChannelsPerFrame))
        filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: channels)
        stepPeaks = Array(repeating: 0, count: channels)
        stepLength = max(1, Int(sampleRate / 10))
        // Gain changes glide over about 10 ms, so they don't click.
        smoothing = 1 - exp(-1 / (0.01 * sampleRate))
        expected = -1
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, start: CMTime) {
        guard isFloat, frames > 0, let owner else { return }
        let startSeconds = start.isNumeric ? start.seconds : max(0, expected)
        let spans = owner.spans
        let jumped = abs(startSeconds - expected) > 0.05
        if jumped {
            filters = filters.map { _ in KWeighting(sampleRate: sampleRate) }
            steps.removeAll()
            stepSum = 0
            stepCount = 0
        }

        var spanIndex = -1
        var target = 1.0
        var channelCount = 0
        for buffer in buffers { channelCount += Int(buffer.mNumberChannels) }
        if channelCount != filters.count {
            filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: channelCount)
            stepPeaks = Array(repeating: 0, count: channelCount)
        }

        for frame in 0..<frames {
            let time = startSeconds + Double(frame) / sampleRate
            if spanIndex < 0 || time < spans[spanIndex].start || time >= spans[spanIndex].end {
                spanIndex = spans.firstIndex { time >= $0.start && time < $0.end } ?? -1
                target = spanIndex >= 0 ? Loudness.linear(spans[spanIndex].gainDB) : 1
                if jumped, frame == 0 { gain = target }
            }
            gain += (target - gain) * smoothing
            let applied = Float(gain)

            var channel = 0
            var squares = 0.0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    channel += Int(buffer.mNumberChannels)
                    continue
                }
                let stride = Int(buffer.mNumberChannels)
                for inBuffer in 0..<stride {
                    let index = frame * stride + inBuffer
                    let sample = data[index] * applied
                    data[index] = sample
                    stepPeaks[channel] = max(stepPeaks[channel], abs(sample))
                    let weighted = filters[channel].process(Double(sample))
                    squares += weighted * weighted
                    channel += 1
                }
            }
            stepSum += squares
            stepCount += 1
            if stepCount == stepLength {
                steps.append(stepSum / Double(stepLength))
                if steps.count > 4 { steps.removeFirst() }
                owner.publish(TimelineAudio.Level(
                    time: time,
                    momentary: Loudness.lufs(meanSquare: steps.reduce(0, +) / Double(steps.count)),
                    peaks: stepPeaks.map { Loudness.decibels(Double($0)) },
                    measuredAt: ProcessInfo.processInfo.systemUptime
                ))
                stepSum = 0
                stepCount = 0
                stepPeaks = stepPeaks.map { _ in 0 }
            }
        }
        expected = startSeconds + Double(frames) / sampleRate
    }
}
