import Accelerate
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
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let minFrameDuration = try await track.load(.minFrameDuration)
        let geometry = try await VideoGeometry.load(track)
        let duration = try await asset.load(.duration)

        var sourceFrameDuration = minFrameDuration
        if !sourceFrameDuration.isNumeric || sourceFrameDuration <= .zero {
            sourceFrameDuration = CMTime(value: 1001, timescale: 30000)
        }

        // Output at the picture's real shape, e.g. 720×480 DV → 640×480.
        let size = geometry.displaySize
        let renderSize = CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))

        let instruction = DeinterlaceInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            trackID: track.trackID,
            fieldOrder: fieldOrder,
            sourceFrameDuration: sourceFrameDuration
        )
        return AVVideoComposition(configuration: .init(
            customVideoCompositorClass: DeinterlaceCompositor.self,
            frameDuration: CMTimeMultiplyByRatio(sourceFrameDuration, multiplier: 1, divisor: 2),
            instructions: [instruction],
            renderSize: renderSize
        ))
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

        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let rowLength = min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(destination)) * 4
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(destination)
        let keep = keepOddRows ? 1 : 0

        for y in 0..<height {
            let out = dst + y * dstStride
            if y & 1 == keep || height < 2 {
                memcpy(out, src + y * srcStride, rowLength)
            } else {
                let above = y > 0 ? y - 1 : y + 1
                let below = y + 1 < height ? y + 1 : y - 1
                average(UnsafeRawPointer(src + above * srcStride), UnsafeRawPointer(src + below * srcStride), into: out, count: rowLength)
            }
        }
    }

    private static func average(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, into out: UnsafeMutableRawPointer, count: Int) {
        var i = 0
        while i + 16 <= count {
            let x = a.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
            let y = b.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
            // (x + y) / 2 without overflowing 8 bits.
            let mean = (x &>> 1) &+ (y &>> 1) &+ (x & y & 1)
            out.storeBytes(of: mean, toByteOffset: i, as: SIMD16<UInt8>.self)
            i += 16
        }
        while i < count {
            let mean = (UInt16(a.load(fromByteOffset: i, as: UInt8.self)) + UInt16(b.load(fromByteOffset: i, as: UInt8.self))) / 2
            out.storeBytes(of: UInt8(mean), toByteOffset: i, as: UInt8.self)
            i += 1
        }
    }
}

/// Tells the compositor which track to read and how its fields are ordered.
nonisolated final class DeinterlaceInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let fieldOrder: FieldOrder
    let sourceFrameDuration: CMTime

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, fieldOrder: FieldOrder, sourceFrameDuration: CMTime) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.fieldOrder = fieldOrder
        self.sourceFrameDuration = sourceFrameDuration
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Renders each output frame from one field of the source frame.
/// Output frame 0 uses the first field of source frame 0, output frame 1 the second field, and so on.
nonisolated final class DeinterlaceCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = DeinterlaceCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = DeinterlaceCompositor.bgra

    private let queue = DispatchQueue(label: "FunSize.Deinterlace")
    /// Full-size field frame, reused between frames when the output needs rescaling.
    private var scratch: CVPixelBuffer?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { self.render(request) }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard
            let instruction = request.videoCompositionInstruction as? DeinterlaceInstruction,
            let source = request.sourceFrame(byTrackID: instruction.trackID),
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "FunSize.Deinterlace", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read a video frame to deinterlace.",
            ]))
            return
        }

        // Which half of the source frame this output frame falls in.
        let fieldDuration = instruction.sourceFrameDuration.seconds / 2
        let fieldIndex = Int((request.compositionTime.seconds / fieldDuration).rounded())
        let isFirstField = fieldIndex % 2 == 0
        let useTopField = (instruction.fieldOrder == .topFirst) == isFirstField

        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if width == CVPixelBufferGetWidth(output) && height == CVPixelBufferGetHeight(output) {
            Deinterlacer.bob(source, into: output, keepOddRows: !useTopField)
        } else if let field = scratchBuffer(width: width, height: height) {
            Deinterlacer.bob(source, into: field, keepOddRows: !useTopField)
            Self.scale(field, into: output)
        }
        request.finish(withComposedVideoFrame: output)
    }

    private func scratchBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let scratch, CVPixelBufferGetWidth(scratch) == width, CVPixelBufferGetHeight(scratch) == height {
            return scratch
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        scratch = buffer
        return buffer
    }

    private static func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        var src = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source),
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dst = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(destination),
            height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
            width: vImagePixelCount(CVPixelBufferGetWidth(destination)),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
    }
}
