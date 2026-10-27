import AVFoundation

/// A file's sound drawn as a waveform: the loudest sample in each of many equal slices of
/// the file, in decibels.
nonisolated struct Waveform: Sendable, Equatable {
    /// How many slices a waveform has: 200 a second, so it stays detailed when zoomed in
    /// (at least 2,000 for short files, at most 2 million for very long ones).
    static func sliceCount(duration: Double) -> Int {
        min(2_000_000, max(2_000, Int(duration * 200)))
    }
    /// The quietest level drawn; anything below shows as silence.
    static let floorDB: Float = -60

    /// Each slice's loudest sample, in dB (`floorDB` for silence).
    var peaks: [Float]

    /// A slice's height from 0 (silent) to 1 (full scale). Decibels, so quiet speech still shows.
    func height(at index: Int) -> Float {
        guard peaks.indices.contains(index) else { return 0 }
        return max(0, 1 - peaks[index] / Self.floorDB)
    }

    /// Reads the file's sound (all tracks mixed to mono).
    static func read(url: URL, duration: Double) async throws -> Waveform? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, duration > 0 else { return nil }
        let sampleRate = 8_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let sliceCount = Self.sliceCount(duration: duration)
        let samplesPerSlice = max(1.0, duration * sampleRate / Double(sliceCount))
        var linear = [Float](repeating: 0, count: sliceCount)
        var position = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for index in 0..<(length / 4) {
                    let slice = min(sliceCount - 1, Int(Double(position) / samplesPerSlice))
                    linear[slice] = max(linear[slice], abs(samples[index]))
                    position += 1
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return Waveform(peaks: linear.map { $0 > 0 ? max(floorDB, 20 * log10($0)) : floorDB })
    }
}
