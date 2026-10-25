import AVFoundation
import UniformTypeIdentifiers

/// Reads a clip's metadata and generates its filmstrip thumbnails.
enum MediaLoader {
    static let thumbnailCount = 12

    static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) ?? false
    }

    static func load(_ clip: Clip) async {
        let asset = AVURLAsset(url: clip.url)
        do {
            clip.duration = try await asset.load(.duration).seconds

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (fps, formats) = try await track.load(.nominalFrameRate, .formatDescriptions)
                let geometry = try await VideoGeometry.load(track)
                clip.displaySize = geometry.displaySize
                clip.encodedSize = geometry.encodedSize
                clip.isRotated = geometry.transform.b != 0 || geometry.transform.c != 0
                clip.frameRate = fps
                if let format = formats.first {
                    (clip.isInterlaced, clip.detectedFieldOrder) = Deinterlacer.detect(format)
                    clip.videoCodec = codecName(CMFormatDescriptionGetMediaSubType(format))
                    clip.pixelAspectRatio = pixelAspectRatio(format)
                    clip.colorSpace = colorSpaceName(format)
                }
                clip.videoBitRate = try? await track.load(.estimatedDataRate)
            } else {
                clip.hasVideo = false
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            clip.hasAudio = !audioTracks.isEmpty
            if let audio = audioTracks.first, let format = try? await audio.load(.formatDescriptions).first {
                clip.audioCodec = codecName(CMFormatDescriptionGetMediaSubType(format))
                if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    clip.audioSampleRate = description.mSampleRate
                    clip.audioChannels = Int(description.mChannelsPerFrame)
                }
            }
            // Captions: real caption tracks, or macOS transcribing the audio.
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible), let option = group.options.first {
                clip.captionName = option.displayName
            }
            clip.containerName = (try? clip.url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.localizedDescription
            if let created = try? await asset.load(.creationDate) {
                clip.creationDate = try? await created.load(.dateValue)
            }

            let values = try? clip.url.resourceValues(forKeys: [.fileSizeKey])
            clip.fileSize = Int64(values?.fileSize ?? 0)
            clip.isLoaded = true

            if clip.hasVideo {
                clip.thumbnails = await thumbnails(for: asset, duration: clip.duration)
            }
        } catch {
            clip.loadError = error.localizedDescription
        }
    }

    /// Friendly names for common codecs; otherwise the four-letter code.
    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)",
            "apco": "Apple ProRes 422 Proxy", "apcs": "Apple ProRes 422 LT", "apcn": "Apple ProRes 422",
            "apch": "Apple ProRes 422 HQ", "ap4h": "Apple ProRes 4444", "ap4x": "Apple ProRes 4444 XQ",
            "aprn": "Apple ProRes RAW", "aprh": "Apple ProRes RAW HQ",
            "dvc ": "DV (NTSC)", "dvcp": "DV (PAL)", "dvpp": "DVCPRO (PAL)", "dv5n": "DVCPRO50 (NTSC)", "dv5p": "DVCPRO50 (PAL)",
            "mp4v": "MPEG-4 Video", "mp2v": "MPEG-2 Video", "jpeg": "Motion JPEG", "mjpa": "Motion JPEG A", "mjpb": "Motion JPEG B",
            "2vuy": "Uncompressed 8-bit 4:2:2", "v210": "Uncompressed 10-bit 4:2:2", "av01": "AV1", "vp09": "VP9",
            "aac ": "AAC", "lpcm": "Linear PCM", "sowt": "Linear PCM", "twos": "Linear PCM", "in24": "Linear PCM",
            "in32": "Linear PCM", "fl32": "Linear PCM", ".mp3": "MP3", "ac-3": "Dolby Digital (AC-3)",
            "ec-3": "Dolby Digital Plus", "alac": "Apple Lossless", "opus": "Opus", "flac": "FLAC",
        ]
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = String(bytes: bytes, encoding: .macOSRoman) ?? "?"
        return names[fourCC] ?? fourCC.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func pixelAspectRatio(_ format: CMFormatDescription) -> CGSize? {
        guard let ratio = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: NSNumber],
              let h = ratio[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String],
              let v = ratio[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] else { return nil }
        return CGSize(width: h.doubleValue, height: v.doubleValue)
    }

    private static func colorSpaceName(_ format: CMFormatDescription) -> String? {
        guard let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String else { return nil }
        let names = [
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: "Rec. 709",
            kCMFormatDescriptionColorPrimaries_SMPTE_C as String: "SMPTE-C (NTSC)",
            kCMFormatDescriptionColorPrimaries_EBU_3213 as String: "EBU 3213 (PAL)",
            kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: "Rec. 2020",
            kCMFormatDescriptionColorPrimaries_DCI_P3 as String: "DCI-P3",
            kCMFormatDescriptionColorPrimaries_P3_D65 as String: "Display P3",
        ]
        var name = names[primaries] ?? primaries
        if let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { name += " HLG" }
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { name += " PQ" }
        }
        return name
    }

    private static func thumbnails(for asset: AVURLAsset, duration: Double) async -> [Clip.Thumbnail] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        var result: [Clip.Thumbnail] = []
        for index in 0..<thumbnailCount {
            let seconds = duration * (Double(index) + 0.5) / Double(thumbnailCount)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                result.append(.init(time: seconds, image: image))
            }
        }
        return result
    }
}
