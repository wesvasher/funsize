import AVFoundation

/// Which field of an interlaced frame was captured first.
nonisolated enum FieldOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case topFirst
    case bottomFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topFirst: "Top Field First"
        case .bottomFirst: "Bottom Field First"
        }
    }
}

/// Turns interlaced video (e.g. 60i VHS) into progressive video at double the frame rate (60p)
/// by making every field its own frame ("bob" deinterlacing).
nonisolated enum Deinterlacer {
    /// Reads interlacing info from a video format. `isInterlaced` is nil when the file doesn't say.
    static func detect(_ format: CMFormatDescription) -> (isInterlaced: Bool?, fieldOrder: FieldOrder?) {
        let fieldCount = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber
        let detail = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FieldDetail) as? String

        var order: FieldOrder?
        switch detail {
        case String(kCMFormatDescriptionFieldDetail_TemporalTopFirst), String(kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly):
            order = .topFirst
        case String(kCMFormatDescriptionFieldDetail_TemporalBottomFirst), String(kCMFormatDescriptionFieldDetail_SpatialFirstLineLate):
            order = .bottomFirst
        default:
            order = nil
        }
        return (fieldCount.map { $0.intValue == 2 }, order)
    }

    /// A video composition that plays or exports `asset` deinterlaced at double frame rate,
    /// scaled to correct the pixel shape (720×480 4:3 footage comes out 640×480).
    static func videoComposition(for asset: AVAsset, fieldOrder: FieldOrder) async throws -> AVVideoComposition? {
        try await Enhancer.videoComposition(for: asset, settings: EnhanceSettings(fieldOrder: fieldOrder))
    }

    /// Builds a full frame from one field: copies that field's lines and fills each
    /// missing line with the average of the lines above and below. BGRA buffers.
    ///
    /// - Parameter keepOddRows: `false` keeps the top field (rows 0, 2, 4…), `true` the bottom field.
    static func bob(_ source: CVPixelBuffer, into destination: CVPixelBuffer, keepOddRows: Bool) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(destination) else { return }

        // The per-pixel work is in C (Native/Bob.c) so it stays fast in debug builds.
        funsize_bob(
            src.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(source),
            dst.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(destination),
            min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(destination)) * 4,
            min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination)),
            keepOddRows ? 1 : 0
        )
    }
}
