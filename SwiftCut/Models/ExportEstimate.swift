import CoreGraphics
import Foundation

/// A guess at how big an export will be, from its settings and the video's length, size, and rate.
///
/// Exact for Bit Rate settings and uncompressed audio, close for ProRes (it runs at a known rate
/// for each size), and rough for H.264 and HEVC on Quality settings: how much they compress
/// depends on the picture, so a still scene can come out much smaller than a busy one.
nonisolated struct ExportEstimate: Equatable, Sendable {
    /// Picture size in the exported file (zero for audio-only).
    let frameSize: CGSize
    let framesPerSecond: Double
    let videoBytes: Double
    let audioBytes: Double
    /// `true` when the size depends on the picture (Quality settings).
    let isRough: Bool

    var totalBytes: Double {
        // Container overhead: indexes, timing, and headers, about 1%.
        (videoBytes + audioBytes) * 1.01
    }

    /// The source being exported.
    struct Source: Equatable, Sendable {
        /// Picture size before the preset's resizing.
        var frameSize: CGSize
        var framesPerSecond: Double
        var duration: Double
        /// `nil` when there's no sound.
        var audio: (sampleRate: Double, channels: Int)?

        static func == (a: Source, b: Source) -> Bool {
            a.frameSize == b.frameSize && a.framesPerSecond == b.framesPerSecond && a.duration == b.duration
                && a.audio?.sampleRate == b.audio?.sampleRate && a.audio?.channels == b.audio?.channels
        }
    }

    init(preset: ExportPreset, source: Source) {
        let duration = max(0, source.duration)
        if let video = preset.video {
            let size = video.outputSize(for: source.frameSize)
            let fps = video.frameRate ?? source.framesPerSecond
            frameSize = size
            framesPerSecond = fps
            let bitsPerSecond: Double
            if video.codec.isProRes {
                bitsPerSecond = Self.proResBitsPerSecond(video.codec, size: size, fps: fps)
                isRough = false
            } else if video.rateControl == .bitRate {
                bitsPerSecond = max(0.1, video.bitRateMbps) * 1_000_000
                isRough = false
            } else {
                bitsPerSecond = Self.bitsPerPixel(quality: video.quality, codec: video.codec) * size.width * size.height * fps
                isRough = true
            }
            videoBytes = bitsPerSecond * duration / 8
        } else {
            frameSize = .zero
            framesPerSecond = 0
            videoBytes = 0
            isRough = false
        }

        if let audio = preset.audio, let sound = source.audio {
            var sampleRate = audio.sampleRate ?? sound.sampleRate
            if audio.codec == .aac { sampleRate = min(sampleRate, 48_000) }
            let channels = Double(audio.channels ?? min(max(sound.channels, 1), 2))
            let bitsPerSecond: Double = switch audio.codec {
            case .aac: Double(audio.bitRateKbps) * 1000
            case .pcm: sampleRate * Double(audio.bitDepth) * channels
            // Apple Lossless usually stores about 60% of the uncompressed size.
            case .alac: sampleRate * Double(audio.bitDepth) * channels * 0.6
            }
            audioBytes = bitsPerSecond * duration / 8
        } else {
            audioBytes = 0
        }
    }

    /// Apple's published ProRes rates for 1920 × 1080 at 29.97 fps, scaled to the size and rate.
    static func proResBitsPerSecond(_ codec: ExportPreset.VideoCodec, size: CGSize, fps: Double) -> Double {
        let hdMbps: Double = switch codec {
        case .proRes422Proxy: 45
        case .proRes422LT: 102
        case .proRes422: 147
        case .proRes422HQ: 220
        case .proRes4444: 330
        case .h264, .hevc: 0
        }
        let scale = (size.width * size.height * fps) / (1920 * 1080 * 29.97)
        return hdMbps * 1_000_000 * scale
    }

    /// Typical bits per pixel per frame for H.264 at a quality setting (0…1), for ordinary video.
    /// HEVC needs about 60% as many for the same look.
    static func bitsPerPixel(quality: Double, codec: ExportPreset.VideoCodec) -> Double {
        let q = min(max(quality, 0), 1)
        let h264 = 0.015 + 0.25 * q * q * q
        return codec == .hevc ? h264 * 0.6 : h264
    }
}
