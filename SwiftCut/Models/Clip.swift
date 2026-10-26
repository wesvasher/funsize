import AVFoundation
import CoreImage
import Observation

/// A source video: a video (or audio) file the user imported, used as is.
/// Its in and out marks are where the next subclip will come from.
@Observable
final class Clip: Identifiable {
    struct Thumbnail: Identifiable {
        let id = UUID()
        let time: Double
        let image: CGImage
    }

    let id: UUID
    let url: URL
    let name: String
    /// Saved in the project so the file can be reopened after relaunching.
    var bookmark: Data?

    var duration: Double = 0
    var displaySize: CGSize = .zero
    var frameRate: Float = 0
    var fileSize: Int64 = 0
    var hasVideo = true
    var hasAudio = true
    var thumbnails: [Thumbnail] = []
    var isLoaded = false
    var loadError: String?

    /// Marked range in seconds. `nil` means the start (in) or end (out) of the clip.
    var inPoint: Double?
    var outPoint: Double?

    /// Details shown in the inspector. `nil` when the file doesn't say.
    var containerName: String?
    var videoCodec: String?
    var encodedSize: CGSize = .zero
    var pixelAspectRatio: CGSize?
    var colorSpace: String?
    var videoBitRate: Float?
    var audioCodec: String?
    var audioSampleRate: Double?
    var audioChannels: Int?
    var creationDate: Date?

    /// From the file: `true` interlaced, `false` progressive, `nil` the file doesn't say.
    var isInterlaced: Bool?
    var detectedFieldOrder: FieldOrder?
    /// User choice: turn each field into a frame (60i → 60p).
    var deinterlace = false
    /// User override for field order; `nil` means use what was detected.
    var fieldOrderChoice: FieldOrder?

    /// Field order to use. Without file info, assume bottom first (DV and most SD captures).
    var fieldOrder: FieldOrder { fieldOrderChoice ?? detectedFieldOrder ?? .bottomFirst }

    /// Offer deinterlacing for interlaced files and for any SD video (many SD captures aren't labeled).
    var canDeinterlace: Bool {
        hasVideo && (isInterlaced == true || (displaySize.height > 0 && displaySize.height <= 576))
    }

    var isDeinterlacing: Bool { deinterlace && canDeinterlace }

    /// Frame rate of what plays and exports: doubled when deinterlacing.
    var outputFrameRate: Float { isDeinterlacing ? frameRate * 2 : frameRate }

    // MARK: Captions

    /// Name of the caption option the system offers, e.g. "English (US) Transcribed". `nil` when there are none.
    var captionName: String?
    var hasCaptions: Bool { captionName != nil }
    /// Show captions over the preview.
    var showCaptions = false

    // MARK: Color

    /// "Apple Log" or "Apple Log 2" when the file says it's log footage.
    var logFormat: String?
    /// The LUT chosen in the Color section's LUT part (usually a conversion, like Apple Log), or `nil` for none.
    var lutID: UUID?
    /// 0…1: how strongly the LUT applies.
    var lutIntensity = 1.0
    /// The LUT switch: off keeps the choice but doesn't apply it.
    var lutEnabled = true

    /// The creative look chosen in the Color section's Look part, applied after the LUT.
    var lookID: UUID?
    var lookIntensity = 1.0
    var lookEnabled = true

    /// Color correction from the Grade section, applied after the LUT.
    var grade = ColorGrade()

    /// The chosen LUT, if it's still in the library.
    var lut: ColorLUT? { LUTLibrary.shared.lut(id: lutID) }
    /// The chosen look, if it's still in the library.
    var look: ColorLUT? { LUTLibrary.shared.lut(id: lookID) }

    // MARK: Enhancement

    var denoise = false
    var denoiseStrength = 0.5
    var upscale: UpscaleMode = .off
    /// 0 is off.
    var sharpen = 0.0
    /// Rotated (e.g. portrait phone) video; enhancement effects don't handle rotation yet.
    var isRotated = false
    /// Why the preview couldn't apply the effects, if it couldn't.
    var effectsError: String?

    var canEnhance: Bool { hasVideo && !isRotated && displaySize.width >= 160 && displaySize.height >= 96 }

    /// Everything the preview and exports should apply, in processing order.
    var enhanceSettings: EnhanceSettings {
        EnhanceSettings(
            fieldOrder: isDeinterlacing ? fieldOrder : nil,
            denoiseStrength: canEnhance && denoise ? Float(denoiseStrength) : nil,
            upscale: canEnhance ? upscale : .off,
            sharpen: canEnhance ? Float(sharpen) : 0,
            lut: canEnhance && lutEnabled ? lut.map { AppliedLUT(lut: $0, intensity: Float(lutIntensity)) } : nil,
            look: canEnhance && lookEnabled ? look.map { AppliedLUT(lut: $0, intensity: Float(lookIntensity)) } : nil,
            grade: canEnhance && !grade.isIdentity ? grade : nil
        )
    }

    /// The LUT a newly imported clip gets: the Apple Log conversion from Settings › Color
    /// for Apple Log footage, otherwise none.
    var defaultLUTID: UUID? {
        guard logFormat != nil, let auto = ColorSettings.autoLUTForAppleLog,
              LUTLibrary.shared.lut(id: auto) != nil else { return nil }
        return auto
    }

    /// Whether everything set in the inspector is as it was when the clip was imported.
    var isAtDefaults: Bool {
        !deinterlace && fieldOrderChoice == nil && !showCaptions
            && !denoise && denoiseStrength == 0.5 && upscale == .off && sharpen == 0
            && lutID == defaultLUTID && lutIntensity == 1 && lutEnabled
            && lookID == nil && lookIntensity == 1 && lookEnabled && grade.isIdentity
    }

    /// Puts everything set in the inspector back as it was when the clip was imported:
    /// timing, captions, effects, LUT, look, and grade. In and out marks are kept.
    func resetAll() {
        deinterlace = false
        fieldOrderChoice = nil
        showCaptions = false
        resetEffects()
        lutID = defaultLUTID
        lutIntensity = 1
        lutEnabled = true
        lookID = nil
        lookIntensity = 1
        lookEnabled = true
        grade = ColorGrade()
    }

    /// Turns the Effects section back to its defaults (Timing is left alone).
    func resetEffects() {
        denoise = false
        denoiseStrength = 0.5
        upscale = .off
        sharpen = 0
    }

    /// Picture size after effects (upscaling makes it bigger).
    var outputSize: CGSize {
        enhanceSettings.upscale == .off ? displaySize : Enhancer.outputSize(displaySize: displaySize, upscale: upscale)
    }

    /// Added to exported file names, e.g. "60p Enhanced".
    var exportNameSuffix: String {
        let settings = enhanceSettings
        var parts: [String] = []
        if settings.fieldOrder != nil { parts.append(deinterlacedRateLabel) }
        if settings.denoiseStrength != nil || settings.upscale != .off || settings.sharpen > 0 { parts.append("Enhanced") }
        if settings.colorLook != nil { parts.append("Graded") }
        return parts.joined(separator: " ")
    }

    /// "60p" for 29.97 fps interlaced video, "50p" for PAL.
    var deinterlacedRateLabel: String { "\(Int((frameRate * 2).rounded()))p" }

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }

    // MARK: Saving

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The parts of this clip a project file keeps.
    var record: ProjectFile.ClipRecord {
        var r = ProjectFile.ClipRecord(id: id, url: url, bookmark: bookmark)
        r.inPoint = inPoint
        r.outPoint = outPoint
        r.deinterlace = deinterlace
        r.fieldOrder = fieldOrderChoice
        r.showCaptions = showCaptions
        r.denoise = denoise
        r.denoiseStrength = denoiseStrength
        r.upscale = upscale
        r.sharpen = sharpen
        r.lutID = lutID
        r.lutIntensity = lutIntensity
        r.lutEnabled = lutEnabled
        r.lookID = lookID
        r.lookIntensity = lookIntensity
        r.lookEnabled = lookEnabled
        r.grade = grade
        return r
    }

    /// Takes the saved settings (used when opening a project and for undo).
    /// Only changed values are written so nothing redraws needlessly.
    func apply(_ r: ProjectFile.ClipRecord) {
        if inPoint != r.inPoint { inPoint = r.inPoint }
        if outPoint != r.outPoint { outPoint = r.outPoint }
        if deinterlace != r.deinterlace { deinterlace = r.deinterlace }
        if fieldOrderChoice != r.fieldOrder { fieldOrderChoice = r.fieldOrder }
        if showCaptions != r.showCaptions { showCaptions = r.showCaptions }
        if denoise != r.denoise { denoise = r.denoise }
        if denoiseStrength != r.denoiseStrength { denoiseStrength = r.denoiseStrength }
        if upscale != r.upscale { upscale = r.upscale }
        if sharpen != r.sharpen { sharpen = r.sharpen }
        if lutID != r.lutID { lutID = r.lutID }
        if lutIntensity != r.lutIntensity { lutIntensity = r.lutIntensity }
        if lutEnabled != r.lutEnabled { lutEnabled = r.lutEnabled }
        if lookID != r.lookID { lookID = r.lookID }
        if lookIntensity != r.lookIntensity { lookIntensity = r.lookIntensity }
        if lookEnabled != r.lookEnabled { lookEnabled = r.lookEnabled }
        if grade != r.grade { grade = r.grade }
    }

    var poster: CGImage? { colored(thumbnails.indices.first) }

    var hasMarks: Bool { inPoint != nil || outPoint != nil }

    /// The marked part of the source video: what Add Subclip uses.
    var markedRange: ClosedRange<Double> {
        let start = inPoint ?? 0
        return start...max(start, outPoint ?? duration)
    }

    /// Closest thumbnail to a given time, used to draw filmstrips. Shows the clip's LUT, look, and grade.
    func thumbnail(near time: Double) -> CGImage? {
        colored(thumbnails.indices.min { abs(thumbnails[$0].time - time) < abs(thumbnails[$1].time - time) })
    }

    /// Thumbnails with the current color applied, kept until the color changes.
    @ObservationIgnored private var coloredThumbnails: (look: ColorLook, gradeLUT: ColorLUT?, images: [Int: CGImage])?

    /// The thumbnail at `index` with the clip's LUT, look, and grade (the original when there are none).
    private func colored(_ index: Int?) -> CGImage? {
        guard let index else { return nil }
        let original = thumbnails[index].image
        // Reading the settings here lets thumbnails redraw when the color changes.
        guard let look = enhanceSettings.colorLook else { return original }
        if coloredThumbnails?.look != look {
            // A smaller cube than the video's: plenty for a thumbnail, and quick to make while a slider moves.
            coloredThumbnails = (look, look.grade.isIdentity ? nil : look.grade.makeLUT(size: 17), [:])
        }
        if let cached = coloredThumbnails?.images[index] { return cached }
        let image = ThumbnailColor.apply(look, gradeLUT: coloredThumbnails?.gradeLUT, to: original) ?? original
        coloredThumbnails?.images[index] = image
        return image
    }

    var summary: String {
        var parts = [duration.timecode]
        if hasVideo, displaySize != .zero {
            parts.append("\(Int(displaySize.width))×\(Int(displaySize.height))")
        }
        if hasVideo, frameRate > 0 {
            parts.append(isInterlaced == true
                ? String(format: "%.4gi", frameRate * 2)
                : String(format: "%.4g fps", frameRate))
        }
        return parts.joined(separator: " · ")
    }
}

/// A named part of a source video, made by marking in and out and choosing Add Subclip
/// (or by trimming a whole source video on the timeline). The video file is never changed.
/// Effects and color belong to the source video, so every subclip of it shares them.
@Observable
final class Subclip: Identifiable {
    let id: UUID
    let sourceID: UUID
    var name: String
    /// Range in the source video, in seconds. `end == nil` means the end of the source.
    var start: Double
    var end: Double?

    init(id: UUID = UUID(), sourceID: UUID, name: String, start: Double, end: Double?) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.start = start
        self.end = end
    }

    /// The range within a source video of `duration` seconds.
    func range(in duration: Double) -> ClosedRange<Double> {
        let upper = min(end ?? duration, duration)
        return min(start, upper)...upper
    }

    var record: ProjectFile.SubclipRecord {
        .init(id: id, sourceID: sourceID, name: name, start: start, end: end)
    }

    func apply(_ r: ProjectFile.SubclipRecord) {
        if name != r.name { name = r.name }
        if start != r.start { start = r.start }
        if end != r.end { end = r.end }
    }

    /// URL used to drag this subclip from the sidebar onto the timeline.
    var dragURL: URL { URL(string: "swiftcut-subclip://\(id.uuidString)")! }

    static func id(fromDragURL url: URL) -> UUID? {
        guard url.scheme == "swiftcut-subclip", let host = url.host() else { return nil }
        return UUID(uuidString: host)
    }
}

/// One spot on the timeline: a whole source video, or one of its subclips.
struct TimelineItem: Identifiable, Hashable {
    let id: UUID
    /// The source video.
    let clipID: UUID
    /// The subclip it plays, or `nil` for the whole source video.
    var subclipID: UUID?
    /// Its volume: matching the timeline's loudness target, and turned up or down.
    var audio = ItemAudio()

    init(id: UUID = UUID(), clipID: UUID, subclipID: UUID? = nil, audio: ItemAudio = ItemAudio()) {
        self.id = id
        self.clipID = clipID
        self.subclipID = subclipID
        self.audio = audio
    }

    /// URL used to drag this item around inside the timeline.
    var dragURL: URL { URL(string: "swiftcut-item://\(id.uuidString)")! }

    static func id(fromDragURL url: URL) -> UUID? {
        guard url.scheme == "swiftcut-item", let host = url.host() else { return nil }
        return UUID(uuidString: host)
    }
}

/// A timeline item's volume settings.
nonisolated struct ItemAudio: Codable, Hashable, Sendable {
    /// Turned up or down to the timeline's loudness target, when Match Loudness is on.
    var matchesTarget = true
    /// Extra decibels on top: louder or quieter than the target (or than the clip, without matching).
    var adjustDB = 0.0

    var isDefault: Bool { self == ItemAudio() }
}

enum SidebarItem: Hashable {
    case timeline
    /// A source video.
    case clip(UUID)
    case subclip(UUID)
}

extension Double {
    /// "1:05" or "1:02:05".
    var timecode: String {
        guard isFinite, self > 0 else { return "0:00" }
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "1:05.3" — used where trims need more precision.
    var preciseTimecode: String {
        guard isFinite, self > 0 else { return "0:00.0" }
        let m = Int(self) / 60
        let s = self - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}

/// Applies a clip's color to its thumbnails, the same way the quick color preview does.
nonisolated enum ThumbnailColor {
    /// Frames are treated as Rec. 709 video, as the player shows them.
    private static let space = CGColorSpace(name: CGColorSpace.itur_709)!
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ look: ColorLook, gradeLUT: ColorLUT?, to image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        guard let colored = try? ColorStage.apply(source, look: look, gradeLUT: gradeLUT, space: space) else { return nil }
        return context.createCGImage(colored, from: source.extent, format: .RGBA8, colorSpace: space)
    }
}
