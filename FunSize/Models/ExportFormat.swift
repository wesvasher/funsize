import AVFoundation

/// The one-click export presets shown in the Export menu.
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case hevc
    case proRes
    case hd1080
    case hd720
    case sd480
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "MP4 (H.264)"
        case .hevc: "HEVC (H.265)"
        case .proRes: "ProRes 422"
        case .hd1080: "1080p MP4"
        case .hd720: "720p MP4"
        case .sd480: "480p MP4"
        case .audio: "Audio Only (M4A)"
        }
    }

    var systemImage: String {
        switch self {
        case .mp4: "film"
        case .hevc: "film.stack"
        case .proRes: "camera.aperture"
        case .hd1080, .hd720, .sd480: "arrow.down.right.and.arrow.up.left"
        case .audio: "waveform"
        }
    }

    /// Short label added to the exported file's name.
    var fileSuffix: String {
        switch self {
        case .mp4: "MP4"
        case .hevc: "HEVC"
        case .proRes: "ProRes"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        case .audio: "Audio"
        }
    }

    var presetName: String {
        switch self {
        case .mp4: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .proRes: AVAssetExportPresetAppleProRes422LPCM
        case .hd1080: AVAssetExportPreset1920x1080
        case .hd720: AVAssetExportPreset1280x720
        case .sd480: AVAssetExportPreset640x480
        case .audio: AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .proRes: .mov
        case .audio: .m4a
        default: .mp4
        }
    }

    var fileExtension: String {
        switch self {
        case .proRes: "mov"
        case .audio: "m4a"
        default: "mp4"
        }
    }

    var isAudioOnly: Bool { self == .audio }

    /// Groups for the Export menu.
    static let videoFormats: [ExportFormat] = [.mp4, .hevc, .proRes]
    static let resizeFormats: [ExportFormat] = [.hd1080, .hd720, .sd480]
    static let audioFormats: [ExportFormat] = [.audio]
}
