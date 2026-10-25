import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A saved FunSize project (".funsize").
    nonisolated static let funsizeProject = UTType(exportedAs: "com.wesvasher.funsize.project")
}

/// What a project file stores: which videos are in it, each clip's marks and
/// settings, and the timeline. Pictures and metadata are read from the videos again on open.
nonisolated struct ProjectFile: Codable, Equatable, Sendable {
    var version = 1
    var clips: [ClipRecord] = []
    var timeline: [TimelineRecord] = []

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
        }
    }

    struct TimelineRecord: Codable, Equatable, Sendable {
        var id: UUID
        var clipID: UUID
        var trimStart: Double
        var trimEnd: Double?
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
    static let readableContentTypes: [UTType] = [.funsizeProject]

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
