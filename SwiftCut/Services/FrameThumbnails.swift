import AVFoundation
import Observation

/// Small pictures of individual frames for the zoomed-in filmstrip, read from the file as they
/// come into view (nearest the middle of the view first) and kept for a while.
@Observable
final class FrameThumbnails {
    /// The frames read so far, by zero-based frame number.
    private(set) var images: [Int: CGImage] = [:]

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var fps = 30.0
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var wanted: [Int] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Frames with the clip's color applied, for the color they were made with.
    @ObservationIgnored private var colored: (look: ColorLook, gradeLUT: ColorLUT?, images: [Int: CGImage])?

    /// How many frames to keep.
    private static let limit = 600

    /// Starts over for another file (or frame rate).
    func use(url: URL, fps: Double) {
        guard url != self.url || fps != self.fps else { return }
        worker?.cancel()
        worker = nil
        self.url = url
        self.fps = fps > 0 ? fps : 30
        images = [:]
        colored = nil
        wanted = []
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator
    }

    /// The frames on screen, most important first. Frames no longer wanted stop loading.
    func want(_ frames: [Int]) {
        wanted = frames.filter { images[$0] == nil }
        if worker == nil, !wanted.isEmpty { startWorker() }
    }

    /// A frame's picture with `look` applied, or `nil` until it has been read.
    func image(_ frame: Int, look: ColorLook?) -> CGImage? {
        guard let original = images[frame] else { return nil }
        guard let look, !look.isEmpty else { return original }
        if colored?.look != look {
            colored = (look, look.grade.isIdentity ? nil : look.grade.makeLUT(size: 17), [:])
        }
        if let cached = colored?.images[frame] { return cached }
        let image = ThumbnailColor.apply(look, gradeLUT: colored?.gradeLUT, to: original) ?? original
        colored?.images[frame] = image
        return image
    }

    private func startWorker() {
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let frame = self.nextFrame() {
                // Only this worker uses the generator, one frame at a time.
                guard let found = self.generator else { break }
                nonisolated(unsafe) let generator = found
                // A quarter into the frame, so rounding can't land on the one before.
                let time = CMTime(seconds: (Double(frame) + 0.25) / self.fps, preferredTimescale: 90_000)
                let image = try? await generator.image(at: time).image
                guard !Task.isCancelled else { break }
                self.store(image, for: frame)
            }
            // A cancelled worker was already replaced (see `use`).
            if !Task.isCancelled { self?.worker = nil }
        }
    }

    private func nextFrame() -> Int? {
        while let frame = wanted.first {
            wanted.removeFirst()
            if images[frame] == nil { return frame }
        }
        return nil
    }

    private func store(_ image: CGImage?, for frame: Int) {
        guard let image else { return }
        images[frame] = image
        // Forget the frames farthest from this one once there are too many.
        if images.count > Self.limit {
            let far = images.keys.sorted { abs($0 - frame) > abs($1 - frame) }.prefix(images.count - Self.limit)
            for key in far {
                images[key] = nil
                colored?.images[key] = nil
            }
        }
    }
}
