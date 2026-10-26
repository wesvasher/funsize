import AVFoundation
import CoreImage
import Observation
import VideoToolbox

/// Drives playback, scrubbing, and in/out marking for the clip preview.
@Observable
final class ClipPlayerController {
    let player = AVPlayer()
    private(set) var clip: Clip?
    /// The subclip being viewed. Its range is what In and Out edit; otherwise they edit the
    /// source video's marks.
    private(set) var subclip: Subclip?
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
        // Captions follow the inspector switch, not the system's automatic choice.
        player.appliesMediaSelectionCriteriaAutomatically = false
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

    /// Effects currently built into the preview (with the LUT and grade left out: see `structure`).
    @ObservationIgnored private var appliedSettings = EnhanceSettings()
    /// The LUT and grade the preview shows. Changing them updates it in place, without a rebuild.
    let liveColor = LiveColor()
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

    /// Shows a source video, or one of its subclips (starting at the subclip's in point).
    func load(_ clip: Clip, subclip: Subclip? = nil) {
        // Same object: the source can be swapped for a relinked one with the same id.
        if clip === self.clip {
            guard subclip?.id != self.subclip?.id else { return }
            self.subclip = subclip
            pause()
            seek(to: subclip?.start ?? 0)
            return
        }
        self.subclip = subclip
        self.clip = clip
        pause()
        let item = AVPlayerItem(url: clip.url)
        effectsItem = item
        originalItem = nil
        isShowingOriginal = false
        frameOutputs = [:]
        storedFrames = [:]
        freezeFrame = nil
        colorProxy = nil
        proxyBase = nil
        isAdjustingColor = false
        attachFrameOutput(to: item)
        install(item)
        appliedSettings = EnhanceSettings()
        currentTime = 0
        if let subclip { seek(to: subclip.start) }
    }

    /// Rebuilds the preview so it shows the clip's current effects (deinterlace, noise, upscale, LUT, sharpen).
    /// Grade changes alone don't need this; see `updateGrade()`.
    func applyEffects() async {
        guard let clip else { return }
        let settings = clip.enhanceSettings
        liveColor.value = settings.colorLook ?? ColorLook()
        guard settings.structure != appliedSettings else { return }
        do {
            let item = try await Self.makeItem(url: clip.url, settings: settings, liveColor: liveColor)
            // The comparison version keeps Timing (deinterlace) so both play at the same frame rate.
            let original = settings.hasLook ? try await Self.makeItem(url: clip.url, settings: settings.timingOnly) : nil
            guard self.clip?.id == clip.id, !Task.isCancelled else { return }
            // New versions: frames stored for the old ones no longer apply.
            frameOutputs = [:]
            storedFrames = [:]
            attachFrameOutput(to: item)
            if let original { attachFrameOutput(to: original) }
            effectsItem = item
            originalItem = original
            appliedSettings = settings.structure
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

    /// Shows the clip's current LUT and grade right away. Turning color on or off still needs
    /// `applyEffects()`, which the view runs shortly after.
    func updateColor() {
        guard let clip else { return }
        liveColor.value = clip.enhanceSettings.colorLook ?? ColorLook()
        if isAdjustingColor, !isPlaying {
            // While a slider is dragged, the quick preview shows changes; the full frame catches up on release.
            renderProxy()
        } else if !isPlaying {
            // A one-off change (a menu or switch): show it with the quick preview right away,
            // since a full-size frame (or a rebuild, when color turns on or off) takes a moment.
            previewColorChange()
        } else {
            redrawFrame()
        }
    }

    /// Shows the current color on the quick preview, then swaps in the full frame once it's ready.
    private func previewColorChange() {
        guard let clip else { return }
        adjustmentCount += 1
        let change = adjustmentCount
        isAdjustingColor = true
        let time = currentTime
        Task {
            if proxyBase?.clipID != clip.id || proxyBase?.time != time {
                await loadProxyBase(for: clip, at: time)
            } else {
                renderProxy()
            }
            // Let the quick preview finish drawing.
            for _ in 0..<50 where isRenderingProxy {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard change == adjustmentCount else { return }
            isAdjustingColor = false
            guard colorProxy != nil else {
                // No quick preview (the frame couldn't be read): just redraw the full frame.
                redrawFrame()
                return
            }
            await finishColorAdjustment(change)
        }
    }

    /// Draws the paused frame again so it shows the current color.
    private func redrawFrame() {
        guard appliedSettings.colorLook != nil, let item = effectsItem else { return }
        // The saved still of this version shows the old color.
        storedFrames[ObjectIdentifier(item)] = nil
        if !isPlaying, player.currentItem === item {
            Self.rerender(item)
        }
    }

    /// Makes a paused player draw its frame again with the current color. Seeking to the same
    /// spot isn't enough (the player keeps the frame it has), but a new copy of the composition is.
    private static func rerender(_ item: AVPlayerItem) {
        guard let composition = item.videoComposition,
              let copy = composition.mutableCopy() as? AVVideoComposition else { return }
        item.videoComposition = copy
    }

    // MARK: Quick color preview

    /// A smaller copy of the paused frame with the current color, shown over the player while a
    /// color slider is dragged. Recoloring it is instant, unlike redrawing a full-size frame.
    private(set) var colorProxy: CGImage?
    @ObservationIgnored private var isAdjustingColor = false
    /// The uncolored frame the quick preview starts from.
    @ObservationIgnored private var proxyBase: (clipID: UUID, time: Double, image: ProxyImage)?
    @ObservationIgnored private var isRenderingProxy = false
    @ObservationIgnored private var proxyIsStale = false
    /// Bumped by each drag, so an older drag's cleanup leaves a newer one's preview alone.
    @ObservationIgnored private var adjustmentCount = 0

    /// Longest side of the quick preview.
    static let proxySize: CGFloat = 1280
    /// The preview treats frame values as Rec. 709 video, as the player shows them.
    nonisolated private static let proxySpace = CGColorSpace(name: CGColorSpace.itur_709)!
    nonisolated private static let proxyContext = CIContext(options: [.cacheIntermediates: false])

    /// A picture that can go to a background thread (Core Image images are immutable).
    private struct ProxyImage: @unchecked Sendable { let image: CIImage }

    /// Call when a color slider starts moving.
    func beginColorAdjustment() {
        adjustmentCount += 1
        isAdjustingColor = true
        guard !isPlaying, let clip else { return }
        let time = currentTime
        if let base = proxyBase, base.clipID == clip.id, base.time == time {
            renderProxy()
            return
        }
        Task { await loadProxyBase(for: clip, at: time) }
    }

    /// Call when a color slider is released. The quick preview stays until the full frame is ready.
    func endColorAdjustment() {
        isAdjustingColor = false
        let drag = adjustmentCount
        Task { await finishColorAdjustment(drag) }
    }

    private func loadProxyBase(for clip: Clip, at time: Double) async {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.proxySize, height: Self.proxySize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let (frame, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 90_000)),
              self.clip?.id == clip.id else { return }
        // Keep the frame's own color space: relabeling it as Rec. 709 shifts the colors.
        proxyBase = (clip.id, time, ProxyImage(image: CIImage(cgImage: frame)))
        if isAdjustingColor { renderProxy() }
    }

    /// Recolors the quick preview in the background. Only the newest settings are drawn.
    private func renderProxy() {
        guard isAdjustingColor, let base = proxyBase, base.clipID == clip?.id else { return }
        guard !isRenderingProxy else {
            proxyIsStale = true
            return
        }
        isRenderingProxy = true
        let (look, gradeLUT) = liveColor.snapshot()
        let source = base.image
        Task.detached(priority: .userInitiated) {
            let image = (try? ColorStage.apply(source.image, look: look, gradeLUT: gradeLUT, space: Self.proxySpace)) ?? source.image
            let frame = Self.proxyContext.createCGImage(image, from: source.image.extent, format: .RGBA8, colorSpace: Self.proxySpace)
            await self.proxyRendered(frame)
        }
    }

    private func proxyRendered(_ frame: CGImage?) {
        isRenderingProxy = false
        if isAdjustingColor, let frame { colorProxy = frame }
        if proxyIsStale {
            proxyIsStale = false
            renderProxy()
        }
    }

    /// Brings the full-size frame up to date, then removes the quick preview.
    private func finishColorAdjustment(_ drag: Int) async {
        guard colorProxy != nil || isRenderingProxy else { return }
        // A rebuild may be on its way (when color was just turned on or off).
        for _ in 0..<60 {
            if let clip, clip.enhanceSettings.structure == appliedSettings { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let item = effectsItem, player.currentItem === item, !isPlaying {
            storedFrames[ObjectIdentifier(item)] = nil
            Self.rerender(item)
            if let output = frameOutputs[ObjectIdentifier(item)] {
                for _ in 0..<100 where !output.hasNewPixelBuffer(forItemTime: item.currentTime()) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            // Give the player view a moment to draw the new frame before uncovering it.
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !isAdjustingColor, drag == adjustmentCount else { return }
        colorProxy = nil
    }

    private static func makeItem(url: URL, settings: EnhanceSettings, liveColor: LiveColor? = nil) async throws -> AVPlayerItem {
        let playable = try await Enhancer.makePlayable(url: url, settings: settings, liveColor: liveColor)
        let item = AVPlayerItem(asset: playable.asset)
        item.videoComposition = playable.videoComposition
        return item
    }

    /// Shows or hides captions on the current preview to match the clip's setting.
    func updateCaptions() async {
        guard let item = player.currentItem else { return }
        await applyCaptions(to: item)
    }

    private func applyCaptions(to item: AVPlayerItem) async {
        guard let clip, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        let option = clip.showCaptions ? group.options.first : nil
        item.select(option, in: group)
    }

    /// The frame on screen at full size, as the viewer shows it (effects, LUT, and grade;
    /// without them while Show Original is held).
    func currentFrameImage() async throws -> CGImage {
        guard let item = player.currentItem, clip?.hasVideo == true else {
            throw EnhanceError.failed("There's no video frame to copy.")
        }
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: item.currentTime()).image
    }

    private func install(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        Task { await applyCaptions(to: item) }
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
            seek(to: inPoint ?? 0)
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

    /// In point being edited: the subclip's start, or the source video's mark.
    var inPoint: Double? {
        get { subclip.map(\.start) ?? clip?.inPoint }
        set {
            if let subclip { subclip.start = newValue ?? 0 } else { clip?.inPoint = newValue }
        }
    }

    /// Out point being edited. A subclip's is never `nil` here (it ends at the end of the source).
    var outPoint: Double? {
        get { subclip.map { min($0.end ?? duration, duration) } ?? clip?.outPoint }
        set {
            if let subclip { subclip.end = newValue } else { clip?.outPoint = newValue }
        }
    }

    /// A subclip always has a range; a source video only once something is marked.
    var hasMarks: Bool { subclip != nil || inPoint != nil || outPoint != nil }

    var markedRange: ClosedRange<Double> {
        let start = inPoint ?? 0
        return start...max(start, outPoint ?? duration)
    }

    /// Marks the frame on screen as the first frame of the range.
    func markIn() {
        guard clip != nil else { return }
        let time = clock.seconds(ofFrame: clock.frameIndex(at: currentTime))
        if let out = outPoint, out <= time { outPoint = nil }
        inPoint = time
    }

    /// Marks the frame on screen as the last frame of the range.
    func markOut() {
        guard clip != nil else { return }
        let time = min(duration, clock.seconds(ofFrame: clock.frameIndex(at: currentTime) + 1))
        if let inPoint, inPoint >= time { self.inPoint = nil }
        outPoint = time
    }

    /// Moves the in point to the frame boundary nearest `seconds` and shows that frame.
    func dragIn(to seconds: Double) {
        guard clip != nil else { return }
        let outBoundary = Int(((outPoint ?? duration) * clock.fps).rounded())
        let boundary = min(max(0, Int((seconds * clock.fps).rounded())), max(0, outBoundary - 1))
        inPoint = clock.seconds(ofFrame: boundary)
        pause()
        seek(to: clock.seconds(ofFrame: boundary))
    }

    /// Moves the out point to the frame boundary nearest `seconds` and shows the last included frame.
    func dragOut(to seconds: Double) {
        guard clip != nil else { return }
        let inBoundary = Int(((inPoint ?? 0) * clock.fps).rounded())
        let boundary = min(max(inBoundary + 1, Int((seconds * clock.fps).rounded())), frameCount)
        outPoint = min(duration, clock.seconds(ofFrame: boundary))
        pause()
        seek(to: clock.seconds(ofFrame: boundary - 1))
    }

    /// Clears a source video's marks. A subclip keeps its range.
    func clearInOut() {
        guard subclip == nil else { return }
        clip?.inPoint = nil
        clip?.outPoint = nil
    }

    func goToIn() {
        pause()
        seek(to: inPoint ?? 0)
    }

    func goToOut() {
        pause()
        guard clip != nil else { return }
        // Land on the last marked frame, not the frame after it.
        let end = outPoint ?? duration
        seek(to: clock.seconds(ofFrame: max(0, clock.frameIndex(at: end) - 1)))
    }
}
