import AVFoundation
import Observation

/// A video (or audio) file the user dropped into the media list.
@Observable
final class Clip: Identifiable {
    struct Thumbnail: Identifiable {
        let id = UUID()
        let time: Double
        let image: CGImage
    }

    let id = UUID()
    let url: URL
    let name: String

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
            sharpen: canEnhance ? Float(sharpen) : 0
        )
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
        return parts.joined(separator: " ")
    }

    /// "60p" for 29.97 fps interlaced video, "50p" for PAL.
    var deinterlacedRateLabel: String { "\(Int((frameRate * 2).rounded()))p" }

    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var poster: CGImage? { thumbnails.first?.image }

    var hasMarks: Bool { inPoint != nil || outPoint != nil }

    /// The part of the clip that exports and goes onto the timeline.
    var markedRange: ClosedRange<Double> {
        let start = inPoint ?? 0
        return start...max(start, outPoint ?? duration)
    }

    /// Closest thumbnail to a given time, used to draw filmstrips.
    func thumbnail(near time: Double) -> CGImage? {
        thumbnails.min { abs($0.time - time) < abs($1.time - time) }?.image
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

/// A clip placed on the timeline, with its own trim.
struct TimelineItem: Identifiable, Hashable {
    let id: UUID
    let clipID: UUID
    var trimStart: Double
    /// `nil` means "to the end of the clip".
    var trimEnd: Double?

    init(clipID: UUID, trimStart: Double = 0, trimEnd: Double? = nil) {
        self.id = UUID()
        self.clipID = clipID
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    /// URL used to drag this item around inside the timeline.
    var dragURL: URL { URL(string: "funsize-item://\(id.uuidString)")! }

    static func id(fromDragURL url: URL) -> UUID? {
        guard url.scheme == "funsize-item", let host = url.host() else { return nil }
        return UUID(uuidString: host)
    }
}

enum SidebarItem: Hashable {
    case timeline
    case clip(UUID)
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
