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

    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var poster: CGImage? { thumbnails.first?.image }

    /// Closest thumbnail to a given time, used to draw filmstrips.
    func thumbnail(near time: Double) -> CGImage? {
        thumbnails.min { abs($0.time - time) < abs($1.time - time) }?.image
    }

    var summary: String {
        var parts = [duration.timecode]
        if hasVideo, displaySize != .zero {
            parts.append("\(Int(displaySize.width))×\(Int(displaySize.height))")
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
