import AVFoundation
import Observation

/// How loud SwiftCut plays, for listening only: it never changes exports or the meters.
/// The same for every window and both players (clip and timeline), and remembered.
///
/// 0 dB, the monitoring level, plays the sound exactly as it will export. Set how loud
/// that is in the room with the Mac's own volume, and leave it there so clips can be
/// judged by ear from day to day.
@Observable
final class MonitorVolume {
    static let shared = MonitorVolume()

    /// The slider's range. The bottom is silence.
    static let range = -60.0...0.0
    static let monitoringLevel = 0.0

    var decibels: Double {
        didSet {
            defaults.set(decibels, forKey: Self.decibelsKey)
            apply()
        }
    }

    var isMuted: Bool {
        didSet {
            defaults.set(isMuted, forKey: Self.mutedKey)
            apply()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var players = NSHashTable<AVPlayer>.weakObjects()

    private static let decibelsKey = "monitorVolumeDB"
    private static let mutedKey = "monitorMuted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.decibelsKey) as? Double ?? Self.monitoringLevel
        decibels = min(Self.range.upperBound, max(Self.range.lowerBound, saved))
        isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    /// The player's volume (0…1).
    var linear: Float {
        guard !isMuted, decibels > Self.range.lowerBound else { return 0 }
        return Float(Loudness.linear(decibels))
    }

    var isAtMonitoringLevel: Bool { !isMuted && decibels == Self.monitoringLevel }

    func setMonitoringLevel() {
        decibels = Self.monitoringLevel
        isMuted = false
    }

    /// Keeps `player`'s volume in step from now on.
    func attach(_ player: AVPlayer) {
        players.add(player)
        player.volume = linear
    }

    private func apply() {
        let volume = linear
        for player in players.allObjects { player.volume = volume }
    }
}
