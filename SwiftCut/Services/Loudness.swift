import AVFoundation

/// Loudness as broadcasters and streaming services measure it (ITU-R BS.1770 / EBU R128),
/// in LUFS: 0 is as loud as digital audio goes, −14 is typical for online video, −23 for TV.
/// Unlike peak level, it follows how loud people hear the sound, so clips at the same LUFS
/// sound equally loud.
nonisolated enum Loudness {
    /// Quieter than this counts as silence.
    static let silence = -70.0

    /// How loud a part of a file is.
    struct Measurement: Codable, Hashable, Sendable {
        /// Integrated loudness in LUFS, or `nil` when it's silent.
        var integrated: Double?
        /// The loudest sample, in dB below full scale (0 is the most digital audio can hold).
        var peak: Double
    }

    /// Reads the sound in `range` (seconds) of the file and measures it. `nil` when it has no sound.
    static func measure(url: URL, range: ClosedRange<Double>) async throws -> Measurement? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 48_000),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 48_000))
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

        var meter = IntegratedMeter(sampleRate: 48_000, channels: 2)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                meter.add(interleaved: UnsafeBufferPointer(start: samples, count: length / 4))
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return meter.result
    }

    /// LUFS from the sum of the channels' mean squares (after K-weighting).
    static func lufs(meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    static func decibels(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : -.infinity
    }

    static func linear(_ decibels: Double) -> Double {
        pow(10, decibels / 20)
    }
}

/// The "K" filter BS.1770 runs before measuring: a gentle treble boost (as the head
/// does) and a cut below about 40 Hz (which people hardly hear).
nonisolated struct KWeighting {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        // Coefficients for any sample rate (as libebur128 derives them); at 48 kHz they
        // match the standard's table exactly.
        do {
            let frequency = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * frequency / sampleRate)
            let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
        do {
            let frequency = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * frequency / sampleRate)
            let a0 = 1 + k / q + k * k
            highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
    }

    mutating func process(_ x: Double) -> Double {
        highPass.process(shelf.process(x))
    }
}

/// Integrated loudness: 400 ms blocks every 100 ms, ignoring silence and quiet stretches
/// (more than 10 LU below the rest), as BS.1770-4 describes.
nonisolated struct IntegratedMeter {
    private let channels: Int
    private var filters: [KWeighting]
    private let stepLength: Int
    /// Mean square of each 100 ms step, summed over channels.
    private var steps: [Double] = []
    private var current = 0.0
    private var currentCount = 0
    private var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        self.channels = channels
        filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: channels)
        stepLength = max(1, Int(sampleRate / 10))
    }

    mutating func add(interleaved samples: UnsafeBufferPointer<Float>) {
        var index = 0
        while index + channels <= samples.count {
            var sum = 0.0
            for channel in 0..<channels {
                let sample = samples[index + channel]
                peak = max(peak, abs(sample))
                let weighted = filters[channel].process(Double(sample))
                sum += weighted * weighted
            }
            current += sum
            currentCount += 1
            if currentCount == stepLength {
                steps.append(current / Double(stepLength))
                current = 0
                currentCount = 0
            }
            index += channels
        }
    }

    var result: Loudness.Measurement {
        var steps = steps
        if currentCount > 0, steps.count < 4 { steps.append(current / Double(currentCount)) }
        // Blocks of four steps (400 ms), overlapping by three. Short clips make one block.
        let blocks: [Double] = steps.count < 4
            ? (steps.isEmpty ? [] : [steps.reduce(0, +) / Double(steps.count)])
            : (0...(steps.count - 4)).map { start in steps[start..<(start + 4)].reduce(0, +) / 4 }
        let audible = blocks.filter { Loudness.lufs(meanSquare: $0) > Loudness.silence }
        var integrated: Double?
        if !audible.isEmpty {
            let relativeGate = Loudness.lufs(meanSquare: audible.reduce(0, +) / Double(audible.count)) - 10
            let kept = audible.filter { Loudness.lufs(meanSquare: $0) > relativeGate }
            if !kept.isEmpty {
                integrated = Loudness.lufs(meanSquare: kept.reduce(0, +) / Double(kept.count))
            }
        }
        return Loudness.Measurement(integrated: integrated, peak: max(-120, Loudness.decibels(Double(peak))))
    }
}
