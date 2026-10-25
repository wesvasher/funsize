import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A saved recipe for exporting: file type, video and audio compression, size, and frame rate.
/// Users can edit these in Settings › Export Presets, and share them as `.funsizepresets` files.
nonisolated struct ExportPreset: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Added to exported file names: "Clip - MP4.mp4".
    var fileSuffix: String
    var container: Container
    /// `nil` exports audio only.
    var video: Video?
    /// `nil` leaves the sound out.
    var audio: Audio?
    /// Puts the file's index at the front so it can start playing while downloading.
    var optimizeForNetwork = true

    // MARK: File type

    enum Container: String, Codable, CaseIterable, Identifiable, Sendable {
        case mp4, mov, m4v, m4a, wav

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mp4: "MPEG-4 (.mp4)"
            case .mov: "QuickTime (.mov)"
            case .m4v: "MPEG-4 Video (.m4v)"
            case .m4a: "Audio Only, MPEG-4 (.m4a)"
            case .wav: "Audio Only, WAVE (.wav)"
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            case .m4v: .m4v
            case .m4a: .m4a
            case .wav: .wav
            }
        }

        var fileExtension: String { rawValue }
        var holdsVideo: Bool { self == .mp4 || self == .mov || self == .m4v }

        var videoCodecs: [VideoCodec] {
            switch self {
            case .mov: VideoCodec.allCases
            case .mp4, .m4v: [.h264, .hevc]
            case .m4a, .wav: []
            }
        }

        var audioCodecs: [AudioCodec] {
            switch self {
            case .mp4, .m4v: [.aac]
            case .mov: AudioCodec.allCases
            case .m4a: [.aac, .alac]
            case .wav: [.pcm]
            }
        }

        var canOptimizeForNetwork: Bool { self != .wav }
    }

    // MARK: Video

    enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
        case h264, hevc, proRes422Proxy, proRes422LT, proRes422, proRes422HQ, proRes4444

        var id: String { rawValue }

        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC (H.265)"
            case .proRes422Proxy: "Apple ProRes 422 Proxy"
            case .proRes422LT: "Apple ProRes 422 LT"
            case .proRes422: "Apple ProRes 422"
            case .proRes422HQ: "Apple ProRes 422 HQ"
            case .proRes4444: "Apple ProRes 4444"
            }
        }

        var shortTitle: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .proRes422Proxy: "ProRes Proxy"
            case .proRes422LT: "ProRes LT"
            case .proRes422: "ProRes 422"
            case .proRes422HQ: "ProRes HQ"
            case .proRes4444: "ProRes 4444"
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            case .proRes422Proxy: .proRes422Proxy
            case .proRes422LT: .proRes422LT
            case .proRes422: .proRes422
            case .proRes422HQ: .proRes422HQ
            case .proRes4444: .proRes4444
            }
        }

        /// ProRes picks its own data rate; H.264 and HEVC take quality or bit rate settings.
        var hasCompressionSettings: Bool { self == .h264 || self == .hevc }
        var isProRes: Bool { !hasCompressionSettings }
    }

    enum FrameSize: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Same size as the clip (after shape correction and effects).
        case source
        /// Shrinks (or grows) to fit inside width × height, keeping the picture's shape.
        case fitWithin
        /// Exactly width × height.
        case exact

        var id: String { rawValue }

        var title: String {
            switch self {
            case .source: "Same as Source"
            case .fitWithin: "Fit Within"
            case .exact: "Exact Size"
            }
        }
    }

    /// How a picture fills an exact size with a different shape.
    enum Scaling: String, Codable, CaseIterable, Identifiable, Sendable {
        case fit, fill, stretch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fit: "Fit (add black bars)"
            case .fill: "Fill (crop the edges)"
            case .stretch: "Stretch"
            }
        }

        var avMode: String {
            switch self {
            case .fit: AVVideoScalingModeResizeAspect
            case .fill: AVVideoScalingModeResizeAspectFill
            case .stretch: AVVideoScalingModeResize
            }
        }
    }

    enum RateControl: String, Codable, CaseIterable, Identifiable, Sendable {
        case quality, bitRate

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quality: "Quality"
            case .bitRate: "Bit Rate"
            }
        }
    }

    struct Video: Codable, Hashable, Sendable {
        var codec: VideoCodec = .h264
        var frameSize: FrameSize = .source
        var width = 1920
        var height = 1080
        var scaling: Scaling = .fit
        /// For Fit Within: also make smaller videos bigger.
        var enlarges = false
        /// Frames per second, or `nil` to keep the source rate.
        var frameRate: Double?
        var rateControl: RateControl = .quality
        /// 0…1, used with `.quality`.
        var quality = 0.8
        /// Megabits per second, used with `.bitRate`.
        var bitRateMbps = 10.0
        /// Frames between keyframes; 0 lets the encoder decide.
        var keyframeInterval = 0

        /// Output picture size for a source of `source` size. Always even, as encoders need.
        func outputSize(for source: CGSize) -> CGSize {
            switch frameSize {
            case .source:
                return Self.even(source)
            case .fitWithin:
                guard source.width > 0, source.height > 0 else { return Self.even(CGSize(width: width, height: height)) }
                var scale = min(Double(width) / source.width, Double(height) / source.height)
                if !enlarges { scale = min(scale, 1) }
                return Self.even(CGSize(width: source.width * scale, height: source.height * scale))
            case .exact:
                return Self.even(CGSize(width: width, height: height))
            }
        }

        var scalingMode: String { frameSize == .exact ? scaling.avMode : AVVideoScalingModeResizeAspect }

        static func even(_ size: CGSize) -> CGSize {
            CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
        }
    }

    // MARK: Audio

    enum AudioCodec: String, Codable, CaseIterable, Identifiable, Sendable {
        case aac, alac, pcm

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aac: "AAC"
            case .alac: "Apple Lossless"
            case .pcm: "Uncompressed (PCM)"
            }
        }

        var shortTitle: String {
            switch self {
            case .aac: "AAC"
            case .alac: "Apple Lossless"
            case .pcm: "PCM"
            }
        }
    }

    struct Audio: Codable, Hashable, Sendable {
        var codec: AudioCodec = .aac
        /// AAC only.
        var bitRateKbps = 192
        /// Apple Lossless and PCM.
        var bitDepth = 16
        /// Hz, or `nil` to keep the source rate.
        var sampleRate: Double?
        /// 1 or 2, or `nil` to keep the source (more than two are mixed to stereo).
        var channels: Int?
    }

    // MARK: Helpers

    var isAudioOnly: Bool { video == nil }

    var systemImage: String {
        guard let video else { return "waveform" }
        if video.codec.isProRes { return "camera.aperture" }
        if video.frameSize != .source { return "arrow.down.right.and.arrow.up.left" }
        return "film"
    }

    /// One line describing the settings, for lists.
    var summary: String {
        var parts = [container.fileExtension.uppercased()]
        if let video {
            parts.append(video.codec.shortTitle)
            switch video.frameSize {
            case .source: break
            case .fitWithin: parts.append("fit \(video.width)×\(video.height)")
            case .exact: parts.append("\(video.width)×\(video.height)")
            }
            if let rate = video.frameRate { parts.append(Self.rateTitle(rate)) }
            if video.codec.hasCompressionSettings {
                parts.append(video.rateControl == .quality
                    ? "quality \(Int((video.quality * 100).rounded()))%"
                    : String(format: "%g Mbps", video.bitRateMbps))
            }
        }
        if let audio {
            parts.append(audio.codec == .aac ? "AAC \(audio.bitRateKbps) kbps" : audio.codec.shortTitle)
        } else if video != nil {
            parts.append("no audio")
        }
        return parts.joined(separator: " · ")
    }

    static func rateTitle(_ fps: Double) -> String {
        String(format: "%g fps", fps)
    }

    /// Makes the settings fit together after the file type changes.
    mutating func normalize() {
        if container.holdsVideo {
            if video == nil { video = Video() }
            if let codec = video?.codec, !container.videoCodecs.contains(codec) {
                video?.codec = container.videoCodecs[0]
            }
        } else {
            video = nil
            if audio == nil { audio = Audio() }
        }
        if let codec = audio?.codec, !container.audioCodecs.contains(codec) {
            audio?.codec = container.audioCodecs[0]
        }
        if !container.canOptimizeForNetwork { optimizeForNetwork = false }
    }

    var normalized: ExportPreset {
        var copy = self
        copy.normalize()
        return copy
    }

    /// Copies this preset under a new id (for Duplicate).
    func copy(named name: String) -> ExportPreset {
        var copy = self
        copy.id = UUID()
        copy.name = name
        return copy
    }

    /// Frame duration for a rate, using exact NTSC timing for 23.976, 29.97, and 59.94.
    static func frameDuration(fps: Double) -> CMTime {
        let rounded = (fps * 1.001).rounded()
        if abs(fps - rounded / 1.001) < 0.005, abs(fps - fps.rounded()) > 0.005 {
            return CMTime(value: 1001, timescale: CMTimeScale(rounded * 1000))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
    }

    static let frameRateChoices: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    // MARK: Built-in presets

    static let defaults: [ExportPreset] = [
        ExportPreset(
            id: UUID(uuidString: "29D8082C-A410-41C2-ABE9-58992A6BA286")!,
            name: "MP4 (H.264)", fileSuffix: "MP4", container: .mp4,
            video: Video(codec: .h264, quality: 0.8), audio: Audio()
        ),
        ExportPreset(
            id: UUID(uuidString: "8029DEF6-7AC6-4D4B-B3CC-35DB3A10EEF8")!,
            name: "HEVC (H.265)", fileSuffix: "HEVC", container: .mp4,
            video: Video(codec: .hevc, quality: 0.75), audio: Audio()
        ),
        ExportPreset(
            id: UUID(uuidString: "5767DE81-4E51-449E-BF92-2D0DD7FF333C")!,
            name: "ProRes 422", fileSuffix: "ProRes", container: .mov,
            video: Video(codec: .proRes422), audio: Audio(codec: .pcm, bitDepth: 16), optimizeForNetwork: false
        ),
        ExportPreset(
            id: UUID(uuidString: "5D6C177E-A57E-477E-83F2-F2A9A73C54CB")!,
            name: "1080p MP4", fileSuffix: "1080p", container: .mp4,
            video: Video(codec: .h264, frameSize: .fitWithin, width: 1920, height: 1080, quality: 0.75), audio: Audio()
        ),
        ExportPreset(
            id: UUID(uuidString: "9AC45D39-F61F-4E3C-B9E0-4EB0F49996A3")!,
            name: "720p MP4", fileSuffix: "720p", container: .mp4,
            video: Video(codec: .h264, frameSize: .fitWithin, width: 1280, height: 720, quality: 0.7), audio: Audio(bitRateKbps: 160)
        ),
        ExportPreset(
            id: UUID(uuidString: "7CFEE44C-3E08-4979-83ED-3CCBC598F8B3")!,
            name: "480p MP4", fileSuffix: "480p", container: .mp4,
            video: Video(codec: .h264, frameSize: .fitWithin, width: 854, height: 480, quality: 0.7), audio: Audio(bitRateKbps: 128)
        ),
        ExportPreset(
            id: UUID(uuidString: "E12271DD-3A64-4D96-9A20-0A4568C70D37")!,
            name: "Audio Only (M4A)", fileSuffix: "Audio", container: .m4a,
            video: nil, audio: Audio(bitRateKbps: 256)
        ),
    ]
}

// MARK: Sharing presets as files

extension UTType {
    /// One or more export presets (".funsizepresets").
    nonisolated static let funsizePresets = UTType(exportedAs: "com.wesvasher.funsize.presets", conformingTo: .json)
}

/// The contents of a `.funsizepresets` file.
nonisolated struct PresetFile: Codable, Sendable {
    var version = 1
    var presets: [ExportPreset]
}

nonisolated struct PresetsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.funsizePresets, .json]

    var presets: [ExportPreset]

    init(presets: [ExportPreset]) {
        self.presets = presets
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        presets = try Self.decode(data)
    }

    /// Reads a presets file, or a file holding a single preset.
    static func decode(_ data: Data) throws -> [ExportPreset] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(PresetFile.self, from: data) { return file.presets.map(\.normalized) }
        if let single = try? decoder.decode(ExportPreset.self, from: data) { return [single.normalized] }
        throw CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "This file doesn't contain FunSize export presets.",
        ])
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(PresetFile(presets: presets)))
    }
}
