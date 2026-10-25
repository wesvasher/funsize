import Foundation
import Observation

/// A saved combination of Effects settings (noise, enhance, sharpen).
struct EffectsPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var denoise: Bool
    var denoiseStrength: Double
    var upscale: UpscaleMode
    var sharpen: Double

    init(name: String, from clip: Clip) {
        self.name = name
        denoise = clip.denoise
        denoiseStrength = clip.denoiseStrength
        upscale = clip.upscale
        sharpen = clip.sharpen
    }

    func apply(to clip: Clip) {
        clip.denoise = denoise
        clip.denoiseStrength = denoiseStrength
        clip.upscale = upscale
        clip.sharpen = sharpen
    }

    /// True when the clip's effects already match this set.
    func matches(_ clip: Clip) -> Bool {
        clip.denoise == denoise && clip.upscale == upscale
            && abs(clip.sharpen - sharpen) < 0.005
            && (!denoise || abs(clip.denoiseStrength - denoiseStrength) < 0.005)
    }
}

/// Saved effect sets, shared by all clips and kept between launches.
@Observable
final class EffectsPresetStore {
    static let shared = EffectsPresetStore()

    private let defaults: UserDefaults
    private let key = "effectsPresets"

    private(set) var presets: [EffectsPreset] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([EffectsPreset].self, from: data) {
            presets = saved
        }
    }

    /// Saves the clip's effects under `name`, replacing a set with the same name.
    func save(name: String, from clip: Clip) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var preset = EffectsPreset(name: trimmed, from: clip)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            preset.id = presets[index].id
            presets[index] = preset
        } else {
            presets.append(preset)
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        persist()
    }

    func delete(_ preset: EffectsPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }
}
