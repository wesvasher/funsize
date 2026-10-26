import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

/// Measuring loudness, and the timeline evening it out.
struct LoudnessTests {
    /// A stereo 1 kHz tone. `amplitude` 0.1 is −20 dB.
    static func tone(in dir: URL, name: String, amplitude: Float, seconds: Double = 3,
                     silentFirstHalf: Bool = false) throws -> URL {
        let url = dir.appending(path: "\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let quiet = silentFirstHalf && frame < Int(frames) / 2
            let sample = quiet ? 0 : amplitude * sin(2 * .pi * 1000 * Float(frame) / 48_000)
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = sample
        }
        try file.write(from: buffer)
        return url
    }

    @Test func toneMeasuresAsTheStandardSays() async throws {
        let dir = try TestVideo.tempDirectory()
        // A 1 kHz tone at −20 dB in both channels is −20 LUFS (BS.1770's reference).
        let url = try Self.tone(in: dir, name: "tone", amplitude: 0.1)
        let measurement = try #require(try await Loudness.measure(url: url, range: 0...3))
        let integrated = try #require(measurement.integrated)
        #expect(abs(integrated - -20) < 0.1, "\(integrated)")
        #expect(abs(measurement.peak - -20) < 0.1, "\(measurement.peak)")
    }

    @Test func silenceDoesNotCount() async throws {
        let dir = try TestVideo.tempDirectory()
        // Half silent: the silence is gated out, so it measures close to the tone alone
        // (blocks that straddle the start of the tone pull it down a little).
        let url = try Self.tone(in: dir, name: "half", amplitude: 0.1, seconds: 4, silentFirstHalf: true)
        let integrated = try #require(try await Loudness.measure(url: url, range: 0...4)?.integrated)
        #expect(abs(integrated - -20) < 1, "\(integrated)")

        let silent = try Self.tone(in: dir, name: "silent", amplitude: 0)
        let measurement = try #require(try await Loudness.measure(url: silent, range: 0...3))
        #expect(measurement.integrated == nil)
    }

    @Test func measuresOnlyTheRange() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try Self.tone(in: dir, name: "half", amplitude: 0.1, seconds: 4, silentFirstHalf: true)
        let measurement = try #require(try await Loudness.measure(url: url, range: 0...1.5))
        #expect(measurement.integrated == nil, "the first half is silent")
    }

    /// Reads the timeline's sound (through its audio mix) and measures `range` of it.
    static func measureMix(_ result: CompositionBuilder.Result, range: ClosedRange<Double>) throws -> Double? {
        let tracks = result.composition.tracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: result.composition)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 48_000),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = result.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var meter = IntegratedMeter(sampleRate: 48_000, channels: 2)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer!.withMemoryRebound(to: Float.self, capacity: length / 4) {
                meter.add(interleaved: UnsafeBufferPointer(start: $0, count: length / 4))
            }
        }
        return meter.result.integrated
    }

    @Test func timelineTurnsEachClipUpOrDown() async throws {
        let dir = try TestVideo.tempDirectory()
        let quiet = try Self.tone(in: dir, name: "quiet", amplitude: 0.02)  // about −34 LUFS
        let loud = try Self.tone(in: dir, name: "loud", amplitude: 0.3)     // about −10.5 LUFS
        // Turn the quiet one up 18 dB and the loud one down 6 dB.
        let audio = TimelineAudio(spans: [.init(start: 0, end: 3, gainDB: 18), .init(start: 3, end: 6, gainDB: -6)])
        let result = try await CompositionBuilder.build([.init(url: quiet, start: 0, end: 3), .init(url: loud, start: 0, end: 3)],
                                                        audio: audio)
        #expect(result.audioMix != nil)
        let first = try #require(try Self.measureMix(result, range: 0.5...2.5))
        let second = try #require(try Self.measureMix(result, range: 3.5...5.5))
        let expectedFirst = Loudness.decibels(0.02) + 18, expectedSecond = Loudness.decibels(0.3) - 6
        #expect(abs(first - expectedFirst) < 0.3, "\(first) vs \(expectedFirst)")
        #expect(abs(second - expectedSecond) < 0.3, "\(second) vs \(expectedSecond)")
    }

    @Test @MainActor func storeEvensOutClipsToTheTarget() async throws {
        let dir = try TestVideo.tempDirectory()
        let quiet = try Self.tone(in: dir, name: "quiet", amplitude: 0.02)
        let loud = try Self.tone(in: dir, name: "loud", amplitude: 0.3)
        let store = ProjectStore(exporter: ExportManager())
        let clips = store.importFiles([quiet, loud])
        for _ in 0..<200 where !clips.allSatisfy(\.isLoaded) {
            try await Task.sleep(for: .milliseconds(50))
        }
        store.addToTimeline(clips.map { .clip($0.id) })
        await store.measureTimelineLoudness()

        let items = store.timeline
        // Matching off: nothing changes.
        #expect(store.timelineAudioSpans.map(\.gainDB) == [0, 0])

        store.timelineSettings.matchLoudness = true
        store.timelineSettings.loudnessTarget = -16
        let quietPlan = store.audioPlan(for: items[0]), loudPlan = store.audioPlan(for: items[1])
        #expect(abs(try #require(loudPlan.result) - -16) < 0.01)
        #expect(loudPlan.gainDB < 0 && !loudPlan.isLimited)
        // The quiet tone peaks at −34 dB, so it can go up 33 dB before distorting: enough for −16.
        #expect(abs(try #require(quietPlan.result) - -16) < 0.01)

        // The loud tone set 20 dB above the target is held back to 1 dB under full scale.
        store.setAudio(ItemAudio(matchesTarget: true, adjustDB: 20), for: items[1].id)
        let pushed = store.audioPlan(for: store.timeline[1])
        #expect(pushed.isLimited)
        #expect(abs(pushed.gainDB - (-1 - Loudness.decibels(0.3))) < 0.05)

        // Not matching: only the clip's own adjustment.
        store.setAudio(ItemAudio(matchesTarget: false, adjustDB: -3), for: items[1].id)
        #expect(store.audioPlan(for: store.timeline[1]).gainDB == -3)
        #expect(store.timelineAudioSpans.count == 2)
    }

    @Test func settingsAndItemsSaveTheirSound() throws {
        var file = ProjectFile()
        file.timelineSettings.matchLoudness = true
        file.timelineSettings.loudnessTarget = -23
        file.timeline = [.init(id: UUID(), clipID: UUID(), subclipID: nil, audio: ItemAudio(matchesTarget: false, adjustDB: 4))]
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: try JSONEncoder().encode(file))
        #expect(decoded == file)
        // Older files without these keys open with matching off.
        let old = try JSONDecoder().decode(TimelineSettings.self, from: Data(#"{"aspect":"automatic"}"#.utf8))
        #expect(!old.matchLoudness && old.loudnessTarget == -16)
    }

    @Test func metersFollowScrubbing() async throws {
        let dir = try TestVideo.tempDirectory()
        let quiet = try Self.tone(in: dir, name: "quiet", amplitude: 0.02)  // peaks at −34 dB
        let loud = try Self.tone(in: dir, name: "loud", amplitude: 0.3)     // peaks at −10.5 dB
        let audio = TimelineAudio(spans: [.init(start: 0, end: 3, gainDB: 10), .init(start: 3, end: 6, gainDB: 0)])
        let result = try await CompositionBuilder.build([.init(url: quiet, start: 0, end: 3), .init(url: loud, start: 0, end: 3)],
                                                        audio: audio)
        audio.envelope = try await TimelineAudio.envelope(of: result.composition)
        #expect(audio.level == nil, "nothing playing or scrubbed yet")

        audio.noteScrub(at: 1.5)
        let first = try #require(audio.level)
        #expect(abs(first.peaks[0] - (Loudness.decibels(0.02) + 10)) < 0.2, "\(first.peaks)")
        #expect(abs(first.momentary - (Loudness.decibels(0.02) + 10)) < 0.3, "\(first.momentary)")

        audio.noteScrub(at: 4.5)
        let second = try #require(audio.level)
        #expect(abs(second.peaks[1] - Loudness.decibels(0.3)) < 0.2, "\(second.peaks)")

        // Changing a clip's volume shows at once, without measuring again.
        audio.spans[1].gainDB = -6
        #expect(abs(try #require(audio.level).peaks[1] - (Loudness.decibels(0.3) - 6)) < 0.2)
    }
}
