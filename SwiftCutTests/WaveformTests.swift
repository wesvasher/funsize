import Foundation
import Testing
@testable import SwiftCut

struct WaveformTests {
    @Test func readsSoundAndSkipsSilentFiles() async throws {
        let dir = try TestVideo.tempDirectory()
        let withSound = try await TestVideo.make(in: dir, name: "sound", seconds: 2, size: CGSize(width: 160, height: 90), audio: true)
        let waveform = try #require(try await Waveform.read(url: withSound, duration: 2))
        #expect(waveform.peaks.count == Waveform.sliceCount(duration: 2))
        #expect(waveform.peaks.contains { $0 > Waveform.floorDB })

        let silent = try await TestVideo.make(in: dir, name: "silent", seconds: 1, size: CGSize(width: 160, height: 90))
        #expect(try await Waveform.read(url: silent, duration: 1) == nil)
    }

    @Test func heightsUseDecibels() {
        let waveform = Waveform(peaks: [0, -30, -60, -90])
        #expect(waveform.height(at: 0) == 1)
        #expect(waveform.height(at: 1) == 0.5)
        #expect(waveform.height(at: 2) == 0)
        #expect(waveform.height(at: 3) == 0)
        #expect(waveform.height(at: 9) == 0)
    }
}
