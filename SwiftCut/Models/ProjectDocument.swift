import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A saved SwiftCut project (".swiftcut").
    nonisolated static let swiftcutProject = UTType(exportedAs: "com.wesvasher.swiftcut.project")
    /// A project saved before the app was renamed from FunSize (".funsize"). Opens and saves the same way.
    nonisolated static let funsizeProject = UTType(importedAs: "com.wesvasher.funsize.project", conformingTo: .data)
}

/// What a project file stores: the source videos (with their marks and settings),
/// subclips, and the timeline. Pictures and metadata are read from the videos again on open.
nonisolated struct ProjectFile: Codable, Equatable, Sendable {
    /// 2 added subclips; timeline items no longer have their own trims.
    var version = 2
    var clips: [ClipRecord] = []
    var subclips: [SubclipRecord] = []
    var timeline: [TimelineRecord] = []
    /// The timeline's frame size, frame rate, and fit.
    var timelineSettings = TimelineSettings()

    init() {}

    init(clips: [ClipRecord], subclips: [SubclipRecord] = [], timeline: [TimelineRecord]) {
        self.clips = clips
        self.subclips = subclips
        self.timeline = timeline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([ClipRecord].self, forKey: .clips) ?? []
        subclips = try c.decodeIfPresent([SubclipRecord].self, forKey: .subclips) ?? []
        timelineSettings = try c.decodeIfPresent(TimelineSettings.self, forKey: .timelineSettings) ?? TimelineSettings()
        // Version 1 trimmed each timeline item; those trims become subclips.
        let names = Dictionary(clips.map { ($0.id, URL(filePath: $0.path).deletingPathExtension().lastPathComponent) },
                               uniquingKeysWith: { first, _ in first })
        var counts: [UUID: Int] = [:]
        timeline = try (c.decodeIfPresent([SavedTimelineItem].self, forKey: .timeline) ?? []).map { saved in
            var record = TimelineRecord(id: saved.id, clipID: saved.clipID, subclipID: saved.subclipID)
            let start = saved.trimStart ?? 0
            if record.subclipID == nil, start > 0 || saved.trimEnd != nil {
                counts[saved.clipID, default: 0] += 1
                let subclip = SubclipRecord(id: UUID(), sourceID: saved.clipID,
                                            name: "\(names[saved.clipID] ?? "Clip") Subclip \(counts[saved.clipID]!)",
                                            start: start, end: saved.trimEnd)
                subclips.append(subclip)
                record.subclipID = subclip.id
            }
            return record
        }
    }

    /// A timeline item as any version saved it.
    private struct SavedTimelineItem: Decodable {
        var id: UUID
        var clipID: UUID
        var subclipID: UUID?
        var trimStart: Double?
        var trimEnd: Double?
    }

    struct ClipRecord: Codable, Equatable, Sendable {
        var id: UUID
        /// Where the video was when last saved, used if the bookmark can't be resolved.
        var path: String
        /// Lets the app reopen the file after relaunching (the app is sandboxed).
        var bookmark: Data?

        var inPoint: Double?
        var outPoint: Double?
        var deinterlace = false
        var fieldOrder: FieldOrder?
        var showCaptions = false
        var denoise = false
        var denoiseStrength = 0.5
        var upscale: UpscaleMode = .off
        var sharpen = 0.0
        var lutID: UUID?
        var lutIntensity = 1.0
        var lutEnabled = true
        var lookID: UUID?
        var lookIntensity = 1.0
        var lookEnabled = true
        var grade = ColorGrade()

        init(id: UUID = UUID(), url: URL, bookmark: Data?) {
            self.id = id
            self.path = url.path(percentEncoded: false)
            self.bookmark = bookmark
        }

        // Fields added in later versions fall back to their defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            path = try c.decode(String.self, forKey: .path)
            bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
            inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint)
            outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint)
            deinterlace = try c.decodeIfPresent(Bool.self, forKey: .deinterlace) ?? false
            fieldOrder = try c.decodeIfPresent(FieldOrder.self, forKey: .fieldOrder)
            showCaptions = try c.decodeIfPresent(Bool.self, forKey: .showCaptions) ?? false
            denoise = try c.decodeIfPresent(Bool.self, forKey: .denoise) ?? false
            denoiseStrength = try c.decodeIfPresent(Double.self, forKey: .denoiseStrength) ?? 0.5
            upscale = try c.decodeIfPresent(UpscaleMode.self, forKey: .upscale) ?? .off
            sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
            lutID = try c.decodeIfPresent(UUID.self, forKey: .lutID)
            lutIntensity = try c.decodeIfPresent(Double.self, forKey: .lutIntensity) ?? 1
            lutEnabled = try c.decodeIfPresent(Bool.self, forKey: .lutEnabled) ?? true
            lookID = try c.decodeIfPresent(UUID.self, forKey: .lookID)
            lookIntensity = try c.decodeIfPresent(Double.self, forKey: .lookIntensity) ?? 1
            lookEnabled = try c.decodeIfPresent(Bool.self, forKey: .lookEnabled) ?? true
            // Projects from before Looks had their own menu kept a built-in look in the LUT slot.
            if lookID == nil, let id = lutID, ColorLUT.builtIns.first(where: { $0.id == id })?.kind == .look {
                lookID = id
                lookIntensity = lutIntensity
                lutID = nil
                lutIntensity = 1
            }
            grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade) ?? ColorGrade()
        }
    }

    struct SubclipRecord: Codable, Equatable, Sendable {
        var id: UUID
        var sourceID: UUID
        var name: String
        var start: Double
        var end: Double?
    }

    struct TimelineRecord: Codable, Equatable, Sendable {
        var id: UUID
        var clipID: UUID
        /// `nil` plays the whole source video.
        var subclipID: UUID?
    }

    /// A new project holding these videos. Call while the app has access to them.
    @MainActor static func with(videos urls: [URL]) -> ProjectFile {
        var file = ProjectFile()
        for url in urls where MediaLoader.isSupported(url) {
            _ = url.startAccessingSecurityScopedResource()
            file.clips.append(ClipRecord(url: url, bookmark: Clip.makeBookmark(for: url)))
        }
        return file
    }
}

/// The document SwiftUI saves and opens. Editing happens in `ProjectStore`;
/// `ProjectWindow` keeps the two in step.
nonisolated struct ProjectDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.swiftcutProject, .funsizeProject]

    var file: ProjectFile

    init(file: ProjectFile = ProjectFile()) {
        self.file = file
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        file = try JSONDecoder().decode(ProjectFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(file))
    }
}
