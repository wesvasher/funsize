import AVFoundation
import Foundation

/// Making a new source video from the clip in the viewer: a new file in the project folder
/// (optionally trimmed to the in and out points, with some settings baked into the picture),
/// imported as a source video of its own.
struct NewSourceOptions: Equatable {
    var name: String
    var presetID: UUID?
    /// Only the in-to-out range; otherwise the whole source video.
    var trimToMarks = true

    // Settings drawn into the new file's picture.
    var bakeTiming = false
    var bakeEffects = false
    var bakeColor = false
    var bakeGrade = false

    /// The new clip starts with this clip's settings for anything not baked in, so it looks
    /// the same and can still be adjusted.
    var inherit = true

    var bakesAnything: Bool { bakeTiming || bakeEffects || bakeColor || bakeGrade }

    /// The clip's settings, keeping only the parts being baked in.
    func bakedSettings(from settings: EnhanceSettings) -> EnhanceSettings {
        var baked = settings
        if !bakeTiming { baked.fieldOrder = nil }
        if !bakeEffects {
            baked.denoiseStrength = nil
            baked.upscale = .off
            baked.sharpen = 0
        }
        if !bakeColor {
            baked.lut = nil
            baked.look = nil
        }
        if !bakeGrade { baked.grade = nil }
        // Scale and position aren't drawn in; they carry over as a setting (see `passSettings`).
        baked.layout = nil
        return baked
    }
}

extension Clip {
    /// Copies settings onto a clip made from this one: inherited parts come across; baked
    /// parts are turned off, since the new file already shows them.
    func passSettings(to new: Clip, options: NewSourceOptions, marks: (in: Double?, out: Double?)) {
        if options.bakeTiming {
            new.deinterlace = false
            new.fieldOrderChoice = nil
        } else if options.inherit {
            new.deinterlace = deinterlace
            new.fieldOrderChoice = fieldOrderChoice
        }
        if options.bakeEffects {
            new.resetEffects()
        } else if options.inherit {
            new.denoise = denoise
            new.denoiseStrength = denoiseStrength
            new.upscale = upscale
            new.sharpen = sharpen
        }
        if options.bakeColor {
            new.lutID = nil
            new.lookID = nil
        } else if options.inherit {
            new.lutID = lutID
            new.lutIntensity = lutIntensity
            new.lutEnabled = lutEnabled
            new.lookID = lookID
            new.lookIntensity = lookIntensity
            new.lookEnabled = lookEnabled
        }
        if options.bakeGrade {
            new.grade = ColorGrade()
        } else if options.inherit {
            new.grade = grade
        }
        if options.inherit {
            new.layout = layout
            new.showCaptions = showCaptions
            // A whole-file copy keeps the marks.
            if !options.trimToMarks {
                new.inPoint = marks.in
                new.outPoint = marks.out
            }
        }
    }
}

extension ProjectStore {
    /// The presets a new source video can be saved with (any with a picture).
    var videoPresets: [ExportPreset] { exporter.presets.filter { !$0.isAudioOnly } }

    /// Saves a new file from `clip` in the project folder and imports it as a source video.
    /// `range` is the in-to-out range to keep (`nil` for the whole file).
    func makeSourceVideo(from clip: Clip, range: ClosedRange<Double>?, marks: (in: Double?, out: Double?),
                         options: NewSourceOptions) {
        guard let preset = videoPresets.first(where: { $0.id == options.presetID }) ?? videoPresets.first else { return }
        let name = options.name.trimmingCharacters(in: .whitespaces).isEmpty ? clip.name : options.name
        guard clip.isLoaded else {
            exporter.reportFailure(clip.loadError ?? "This clip is still loading. Try again in a moment.", name: name, preset: preset)
            return
        }
        let range = options.trimToMarks ? range : nil
        Task {
            guard let folder = await projectFolder(saving: "the new source video", short: "new source videos") else { return }
            let job: ExportJob
            do {
                let settings = options.bakedSettings(from: clip.enhanceSettings)
                let timeRange = range.map {
                    CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 90_000),
                                end: CMTime(seconds: $0.upperBound, preferredTimescale: 90_000))
                }
                if settings.isActive {
                    let playable = try await Enhancer.makePlayable(url: clip.url, settings: settings)
                    job = exporter.export(asset: playable.asset, videoComposition: playable.videoComposition,
                                          timeRange: timeRange, name: name, preset: preset, folder: folder)
                } else {
                    // Through a composition, so the picture shape is corrected as in the preview.
                    let range = range ?? 0...clip.duration
                    let built = try await CompositionBuilder.build([.init(url: clip.url, start: range.lowerBound, end: range.upperBound)])
                    job = exporter.export(asset: built.composition, videoComposition: built.videoComposition,
                                          name: name, preset: preset, folder: folder)
                }
            } catch {
                exporter.reportFailure(error.localizedDescription, name: name, preset: preset)
                return
            }
            await job.task?.value
            guard job.state == .finished, let new = importFiles([job.outputURL]).first, new !== clip else { return }
            // Settings go on once the file has loaded (loading sets some of them, like a LUT for log footage).
            while !new.isLoaded && new.loadError == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            clip.passSettings(to: new, options: options, marks: marks)
        }
    }
}
