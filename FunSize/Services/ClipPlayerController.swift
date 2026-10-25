import AVFoundation
import Observation
import VideoToolbox

/// Drives playback, scrubbing, and in/out marking for the clip preview.
@Observable
final class ClipPlayerController {
    let player = AVPlayer()
    private(set) var clip: Clip?
    var currentTime: Double = 0
    private(set) var isPlaying = false

    /// Playback speed as a multiple of normal (1 = 100%). Separate from the clip's frame rate.
    var playbackSpeed: Float = 1 {
        didSet {
            player.defaultRate = playbackSpeed
            if isPlaying { player.rate = playbackSpeed }
        }
    }

    static let playbackSpeeds: [Float] = [0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4]

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 120), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Effects currently built into the preview.
    @ObservationIgnored private var appliedSettings = EnhanceSettings()
    /// The preview with effects, and the same without the Effects section (for "Show Original").
    @ObservationIgnored private var effectsItem: AVPlayerItem?
    @ObservationIgnored private var originalItem: AVPlayerItem?
    /// True while the user holds "Show Original".
    private(set) var isShowingOriginal = false

    /// A still frame shown over the player while it switches versions, so the view never flashes black.
    private(set) var freezeFrame: CGImage?
    /// Reads decoded frames from each version, to fill `freezeFrame`.
    @ObservationIgnored private var frameOutputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    /// The last frame seen from each version, so switching back shows the right picture at once.
    @ObservationIgnored private var storedFrames: [ObjectIdentifier: (time: CMTime, image: CGImage)] = [:]
    /// Bumped on every switch so an older switch can't remove a newer one's still frame.
    @ObservationIgnored private var switchCount = 0

    func load(_ clip: Clip) {
        guard clip.id != self.clip?.id else { return }
        self.clip = clip
        pause()
        let item = AVPlayerItem(url: clip.url)
        effectsItem = item
        originalItem = nil
        isShowingOriginal = false
        frameOutputs = [:]
        storedFrames = [:]
        freezeFrame = nil
        attachFrameOutput(to: item)
        install(item)
        appliedSettings = EnhanceSettings()
        currentTime = 0
    }

    /// Rebuilds the preview so it shows the clip's current effects (deinterlace, noise, upscale, sharpen).
    func applyEffects() async {
        guard let clip else { return }
        let settings = clip.enhanceSettings
        guard settings != appliedSettings else { return }
        do {
            let item = try await Self.makeItem(url: clip.url, settings: settings)
            // The comparison version keeps Timing (deinterlace) so both play at the same frame rate.
            let original = settings.hasEffects ? try await Self.makeItem(url: clip.url, settings: settings.timingOnly) : nil
            guard self.clip?.id == clip.id, !Task.isCancelled else { return }
            // New versions: frames stored for the old ones no longer apply.
            frameOutputs = [:]
            storedFrames = [:]
            attachFrameOutput(to: item)
            if let original { attachFrameOutput(to: original) }
            effectsItem = item
            originalItem = original
            appliedSettings = settings
            clip.effectsError = nil
            switchVersion(to: isShowingOriginal ? (original ?? item) : item)
        } catch {
            clip.effectsError = error.localizedDescription
        }
    }

    /// Shows the clip without its Effects while `on` is true, then switches back.
    /// Both versions stay loaded, so the switch is immediate and keeps the position.
    func showOriginal(_ on: Bool) {
        guard on != isShowingOriginal else { return }
        isShowingOriginal = on
        guard let target = on ? (originalItem ?? effectsItem) : effectsItem, target !== player.currentItem else { return }
        switchVersion(to: target)
    }

    /// Swaps the player to another version at the same moment, covering the swap with a still frame.
    private func switchVersion(to target: AVPlayerItem) {
        let outgoing = player.currentItem
        let time = outgoing?.currentTime() ?? CMTime(seconds: currentTime, preferredTimescale: 90_000)
        let wasPlaying = isPlaying

        // Show the stored frame of the version we're switching to if it's for this exact moment;
        // otherwise hold the frame that's on screen now.
        let outgoingFrame = outgoing.flatMap { storeFrame(of: $0, at: time) }
        let incomingFrame = storedFrames[ObjectIdentifier(target)].flatMap { $0.time == time ? $0.image : nil }
        freezeFrame = incomingFrame ?? outgoingFrame

        switchCount += 1
        let thisSwitch = switchCount
        install(target)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in await self?.releaseFreezeFrame(after: thisSwitch, item: target, time: time) }
        }
        if wasPlaying { player.playImmediately(atRate: playbackSpeed) }
    }

    /// Removes the still frame once the new version has a frame ready to show.
    private func releaseFreezeFrame(after switchNumber: Int, item: AVPlayerItem, time: CMTime) async {
        if let output = frameOutputs[ObjectIdentifier(item)] {
            for _ in 0..<50 where !output.hasNewPixelBuffer(forItemTime: item.currentTime()) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        _ = storeFrame(of: item, at: time)
        // Give the player view a moment to draw the new frame before uncovering it.
        try? await Task.sleep(for: .milliseconds(40))
        guard switchNumber == switchCount else { return }
        freezeFrame = nil
    }

    private func attachFrameOutput(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        frameOutputs[ObjectIdentifier(item)] = output
    }

    /// Saves the version's frame at `time` and returns it (or the last one saved, if none is new).
    private func storeFrame(of item: AVPlayerItem, at time: CMTime) -> CGImage? {
        let key = ObjectIdentifier(item)
        if let output = frameOutputs[key],
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image {
                storedFrames[key] = (time, image)
                return image
            }
        }
        return storedFrames[key]?.image
    }

    private static func makeItem(url: URL, settings: EnhanceSettings) async throws -> AVPlayerItem {
        let playable = try await Enhancer.makePlayable(url: url, settings: settings)
        let item = AVPlayerItem(asset: playable.asset)
        item.videoComposition = playable.videoComposition
        return item
    }

    private func install(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    // MARK: Timing

    var clock: FrameClock { FrameClock(fps: Double(clip?.outputFrameRate ?? 0)) }
    var duration: Double { clip?.duration ?? 0 }
    var frameCount: Int { clock.frameCount(duration: duration) }

    /// One-based frame number of the frame on screen.
    var currentFrameNumber: Int {
        min(clock.frameIndex(at: currentTime), frameCount - 1) + 1
    }

    // MARK: Playback

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard clip != nil else { return }
        // Start over if we're sitting on the last frame.
        if currentTime >= duration - clock.seconds(ofFrame: 1) {
            seek(to: clip?.inPoint ?? 0)
        }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let time = min(max(0, seconds), duration)
        currentTime = time
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 90_000),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func step(by frames: Int) {
        pause()
        let target = min(max(0, clock.frameIndex(at: currentTime) + frames), frameCount - 1)
        seek(to: clock.seconds(ofFrame: target))
    }

    // MARK: In and out

    /// Marks the frame on screen as the first frame of the range.
    func markIn() {
        guard let clip else { return }
        let time = clock.seconds(ofFrame: clock.frameIndex(at: currentTime))
        clip.inPoint = time
        if let out = clip.outPoint, out <= time { clip.outPoint = nil }
    }

    /// Marks the frame on screen as the last frame of the range.
    func markOut() {
        guard let clip else { return }
        let time = min(duration, clock.seconds(ofFrame: clock.frameIndex(at: currentTime) + 1))
        clip.outPoint = time
        if let inPoint = clip.inPoint, inPoint >= time { clip.inPoint = nil }
    }

    /// Moves the in point to the frame boundary nearest `seconds` and shows that frame.
    func dragIn(to seconds: Double) {
        guard let clip else { return }
        let outBoundary = Int(((clip.outPoint ?? duration) * clock.fps).rounded())
        let boundary = min(max(0, Int((seconds * clock.fps).rounded())), max(0, outBoundary - 1))
        clip.inPoint = clock.seconds(ofFrame: boundary)
        pause()
        seek(to: clock.seconds(ofFrame: boundary))
    }

    /// Moves the out point to the frame boundary nearest `seconds` and shows the last included frame.
    func dragOut(to seconds: Double) {
        guard let clip else { return }
        let inBoundary = Int(((clip.inPoint ?? 0) * clock.fps).rounded())
        let boundary = min(max(inBoundary + 1, Int((seconds * clock.fps).rounded())), frameCount)
        clip.outPoint = min(duration, clock.seconds(ofFrame: boundary))
        pause()
        seek(to: clock.seconds(ofFrame: boundary - 1))
    }

    func clearInOut() {
        clip?.inPoint = nil
        clip?.outPoint = nil
    }

    func goToIn() {
        pause()
        seek(to: clip?.inPoint ?? 0)
    }

    func goToOut() {
        pause()
        guard let clip else { return }
        // Land on the last marked frame, not the frame after it.
        let end = clip.outPoint ?? duration
        seek(to: clock.seconds(ofFrame: max(0, clock.frameIndex(at: end) - 1)))
    }
}
