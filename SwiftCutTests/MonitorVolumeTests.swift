import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

struct MonitorVolumeTests {
    @Test func turnsPlayersDownAndBackToTheMonitoringLevel() throws {
        let defaults = try #require(UserDefaults(suiteName: "MonitorVolumeTests-\(UUID())"))
        let volume = MonitorVolume(defaults: defaults)
        #expect(volume.isAtMonitoringLevel, "starts at 0 dB")

        let player = AVPlayer()
        volume.attach(player)
        #expect(player.volume == 1)

        volume.decibels = -20
        #expect(abs(player.volume - 0.1) < 0.001)
        volume.isMuted = true
        #expect(player.volume == 0)
        volume.isMuted = false
        volume.decibels = MonitorVolume.range.lowerBound
        #expect(player.volume == 0, "the bottom of the slider is silence")

        volume.decibels = -6
        volume.isMuted = true
        volume.setMonitoringLevel()
        #expect(player.volume == 1 && volume.isAtMonitoringLevel)

        // Remembered for next time.
        volume.decibels = -12
        #expect(MonitorVolume(defaults: defaults).decibels == -12)
    }
}
