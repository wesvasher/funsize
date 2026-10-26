import CoreMedia
import Foundation
import Observation

/// The timeline's picture format: frame size (from an aspect ratio and a resolution),
/// frame rate, and how clips of a different shape fit in the frame.
/// "Automatic" follows the clips, as the timeline always did before it had settings.
nonisolated struct TimelineSettings: Codable, Hashable, Sendable {
    enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, widescreen, standard, vertical, portrait, square, cinema

        var id: Self { self }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .widescreen: "16:9 Widescreen"
            case .standard: "4:3 Standard"
            case .vertical: "9:16 Vertical"
            case .portrait: "4:5 Portrait"
            case .square: "1:1 Square"
            case .cinema: "2.39:1 Cinema"
            }
        }
        /// Width divided by height, or `nil` to use the first clip's shape.
        var ratio: Double? {
            switch self {
            case .automatic: nil
            case .widescreen: 16.0 / 9
            case .standard: 4.0 / 3
            case .vertical: 9.0 / 16
            case .portrait: 4.0 / 5
            case .square: 1
            case .cinema: 2.39
            }
        }
    }

    enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, uhd2160, qhd1440, hd1080, hd720, sd480

        var id: Self { self }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .uhd2160: "4K (2160p)"
            case .qhd1440: "1440p"
            case .hd1080: "HD (1080p)"
            case .hd720: "720p"
            case .sd480: "SD (480p)"
            }
        }
        /// The frame's shorter side, or `nil` to use the first clip's.
        var shortSide: Double? {
            switch self {
            case .automatic: nil
            case .uhd2160: 2160
            case .qhd1440: 1440
            case .hd1080: 1080
            case .hd720: 720
            case .sd480: 480
            }
        }
    }

    enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, fps23_976, fps24, fps25, fps29_97, fps30, fps50, fps59_94, fps60

        var id: Self { self }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .fps23_976: "23.976 fps"
            case .fps24: "24 fps"
            case .fps25: "25 fps (PAL)"
            case .fps29_97: "29.97 fps (NTSC)"
            case .fps30: "30 fps"
            case .fps50: "50 fps"
            case .fps59_94: "59.94 fps"
            case .fps60: "60 fps"
            }
        }
        /// Length of one frame, or `nil` to follow the clips' own timing.
        var frameDuration: CMTime? {
            switch self {
            case .automatic: nil
            case .fps23_976: CMTime(value: 1001, timescale: 24000)
            case .fps24: CMTime(value: 1, timescale: 24)
            case .fps25: CMTime(value: 1, timescale: 25)
            case .fps29_97: CMTime(value: 1001, timescale: 30000)
            case .fps30: CMTime(value: 1, timescale: 30)
            case .fps50: CMTime(value: 1, timescale: 50)
            case .fps59_94: CMTime(value: 1001, timescale: 60000)
            case .fps60: CMTime(value: 1, timescale: 60)
            }
        }
    }

    /// How a clip whose shape differs from the frame's is placed.
    enum Fit: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The whole picture shows, with black bars.
        case fit
        /// The frame is filled; the picture's edges are cut off.
        case fill

        var id: Self { self }
        var title: String {
            switch self {
            case .fit: "Fit (Black Bars)"
            case .fill: "Fill (Crop Edges)"
            }
        }
    }

    var aspect = Aspect.automatic
    var resolution = Resolution.automatic
    var frameRate = FrameRate.automatic
    var fit = Fit.fit
    /// The export preset the Export section uses, or `nil` for the first one.
    var exportPresetID: UUID?
    /// Turns each clip up or down so they all reach `loudnessTarget`.
    var matchLoudness = false
    /// In LUFS.
    var loudnessTarget = -16.0

    /// Common loudness targets, loudest first.
    static let loudnessTargets: [(lufs: Double, title: String)] = [
        (-14, "−14 LUFS (Online)"),
        (-16, "−16 LUFS (Podcasts)"),
        (-19, "−19 LUFS (Quiet)"),
        (-23, "−23 LUFS (TV, Europe)"),
        (-24, "−24 LUFS (TV, US)"),
    ]

    init(aspect: Aspect = .automatic, resolution: Resolution = .automatic,
         frameRate: FrameRate = .automatic, fit: Fit = .fit, exportPresetID: UUID? = nil,
         matchLoudness: Bool = false, loudnessTarget: Double = -16) {
        self.aspect = aspect
        self.resolution = resolution
        self.frameRate = frameRate
        self.fit = fit
        self.exportPresetID = exportPresetID
        self.matchLoudness = matchLoudness
        self.loudnessTarget = loudnessTarget
    }

    // Missing or unknown values (older projects, newer choices) fall back to Automatic.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = (try? c.decodeIfPresent(Aspect.self, forKey: .aspect)) ?? .automatic
        resolution = (try? c.decodeIfPresent(Resolution.self, forKey: .resolution)) ?? .automatic
        frameRate = (try? c.decodeIfPresent(FrameRate.self, forKey: .frameRate)) ?? .automatic
        fit = (try? c.decodeIfPresent(Fit.self, forKey: .fit)) ?? .fit
        exportPresetID = try? c.decodeIfPresent(UUID.self, forKey: .exportPresetID)
        matchLoudness = (try? c.decodeIfPresent(Bool.self, forKey: .matchLoudness)) ?? false
        loudnessTarget = (try? c.decodeIfPresent(Double.self, forKey: .loudnessTarget)) ?? -16
    }

    var isDefault: Bool { self == TimelineSettings() }

    /// Without the sound settings, which change the volume without rebuilding the video.
    var pictureOnly: TimelineSettings {
        var copy = self
        copy.matchLoudness = false
        copy.loudnessTarget = -16
        return copy
    }

    /// The frame size in pixels. `firstClip` is the first clip's picture size (used by
    /// Automatic); without one, Automatic means 1920 × 1080.
    func renderSize(firstClip: CGSize?) -> CGSize {
        let base = firstClip.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 1920, height: 1080)
        if aspect == .automatic, resolution == .automatic {
            return CGSize(width: Self.even(base.width), height: Self.even(base.height))
        }
        let ratio = aspect.ratio ?? base.width / base.height
        let short = resolution.shortSide ?? min(base.width, base.height)
        let size = ratio >= 1 ? CGSize(width: short * ratio, height: short) : CGSize(width: short, height: short / ratio)
        return CGSize(width: Self.even(size.width), height: Self.even(size.height))
    }

    /// Video encoders need even sizes (rounded down, as the timeline always did).
    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}

/// Timeline settings saved under a name, to load into other projects.
nonisolated struct TimelinePreset: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var settings: TimelineSettings
}

/// The saved timeline settings (timeline inspector › Save Settings), kept in user defaults.
@Observable
final class TimelinePresetStore {
    static let shared = TimelinePresetStore()

    private let defaults: UserDefaults
    private let key = "timelinePresets"
    private(set) var presets: [TimelinePreset] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([TimelinePreset].self, from: data) {
            presets = saved
        }
    }

    /// Saves `settings` under `name`, replacing a preset with the same name.
    func save(name: String, settings: TimelineSettings) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[index].name = trimmed
            presets[index].settings = settings
        } else {
            presets.append(TimelinePreset(name: trimmed, settings: settings))
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        persist()
    }

    func delete(_ preset: TimelinePreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }
}
