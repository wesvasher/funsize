import AVFoundation
import Observation

/// Drives playback, scrubbing, and in/out marking for the clip preview.
@Observable
final class ClipPlayerController {
    let player = AVPlayer()
    private(set) var clip: Clip?
    var currentTime: Double = 0
    private(set) var isPlaying = false

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

    func load(_ clip: Clip) {
        guard clip.id != self.clip?.id else { return }
        self.clip = clip
        pause()
        let item = AVPlayerItem(url: clip.url)
        player.replaceCurrentItem(with: item)
        currentTime = 0

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    // MARK: Timing

    var clock: FrameClock { FrameClock(fps: Double(clip?.frameRate ?? 0)) }
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
        player.play()
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
