import Foundation

/// Converts between seconds, frame numbers, and MM:SS:FF timecode for one frame rate.
struct FrameClock {
    let fps: Double

    init(fps: Double) {
        self.fps = fps > 0 ? fps : 30
    }

    /// Whole frames per second, used for the FF part of timecode (29.97 → 30).
    var timecodeBase: Int { max(1, Int(fps.rounded())) }

    /// Zero-based index of the frame showing at `seconds`.
    func frameIndex(at seconds: Double) -> Int {
        max(0, Int((seconds * fps + 0.001).rounded(.down)))
    }

    /// Start time of a zero-based frame.
    func seconds(ofFrame index: Int) -> Double {
        Double(index) / fps
    }

    func frameCount(duration: Double) -> Int {
        max(1, Int((duration * fps).rounded()))
    }

    /// "MM:SS:FF", or "H:MM:SS:FF" past an hour.
    func timecode(frames: Int) -> String {
        let base = timecodeBase
        let ff = frames % base
        let totalSeconds = frames / base
        let h = totalSeconds / 3600, m = (totalSeconds % 3600) / 60, s = totalSeconds % 60
        let ffFormat = base > 99 ? "%03d" : "%02d"
        return h > 0
            ? String(format: "%d:%02d:%02d:" + ffFormat, h, m, s, ff)
            : String(format: "%02d:%02d:" + ffFormat, m, s, ff)
    }

    func timecode(seconds: Double) -> String {
        timecode(frames: frameIndex(at: seconds))
    }
}
