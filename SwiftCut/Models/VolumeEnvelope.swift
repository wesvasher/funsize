import Foundation

/// A source video's volume over time, set with keyframes on the clip viewer's waveform.
/// Without keyframes the sound plays as recorded. Before the first keyframe and after the last,
/// the volume stays at that keyframe's level.
///
/// Levels go between keyframes in fader steps (see `position(forDB:)`), so the line drawn on the
/// waveform is what you hear: a straight line is an even fade.
nonisolated struct VolumeEnvelope: Codable, Hashable, Sendable {
    struct Keyframe: Codable, Hashable, Sendable, Identifiable {
        var id = UUID()
        /// Seconds into the source video.
        var time: Double
        /// Volume change in decibels; `minDB` or lower is silent.
        var gainDB: Double
        /// A spline: eases in and out of this keyframe along a curve, rather than meeting it at a corner.
        var isSmooth = true
        /// How much a spline keyframe curves, 0 (nearly straight) to 1 (fully eased).
        var curve = 1.0

        init(id: UUID = UUID(), time: Double, gainDB: Double, isSmooth: Bool = true, curve: Double = 1) {
            self.id = id
            self.time = time
            self.gainDB = gainDB
            self.isSmooth = isSmooth
            self.curve = curve
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            time = try c.decode(Double.self, forKey: .time)
            gainDB = try c.decode(Double.self, forKey: .gainDB)
            isSmooth = try c.decodeIfPresent(Bool.self, forKey: .isSmooth) ?? true
            curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? 1
        }
    }

    /// In time order.
    private(set) var keyframes: [Keyframe] = []

    /// The loudest it goes, and the level counted as silent.
    static let maxDB = 12.0
    static let minDB = -60.0

    var isEmpty: Bool { keyframes.isEmpty }

    // MARK: Fader steps

    /// 0 (silent) to 1 (+12 dB), with 0 dB near the middle: like a fader, so the quiet end
    /// isn't squeezed into a sliver.
    static func position(forDB db: Double) -> Double {
        guard db > minDB else { return 0 }
        let linear = pow(10, min(db, maxDB) / 20)
        return min(1, sqrt(linear) / sqrt(pow(10, maxDB / 20)))
    }

    static func db(forPosition position: Double) -> Double {
        guard position > 0 else { return -.infinity }
        let linear = pow(min(1, position) * sqrt(pow(10, maxDB / 20)), 2)
        let db = 20 * log10(linear)
        return db <= minDB ? -.infinity : db
    }

    /// "+3.0 dB", "−12.5 dB", or "−∞ dB".
    static func label(forDB db: Double) -> String {
        guard db.isFinite, db > minDB else { return "−∞ dB" }
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0 dB" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f dB", abs(rounded))
    }

    // MARK: Reading

    /// Where the line is at `time`, from 0 (silent) to 1.
    func position(at time: Double) -> Double {
        guard let first = keyframes.first, let last = keyframes.last else { return Self.position(forDB: 0) }
        if time <= first.time { return Self.position(forDB: first.gainDB) }
        if time >= last.time { return Self.position(forDB: last.gainDB) }
        // The segment holding `time`.
        var low = 0, high = keyframes.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if keyframes[middle].time <= time { low = middle } else { high = middle }
        }
        return segmentPosition(low, at: time)
    }

    /// The volume change at `time`, in decibels (`-infinity` when silent).
    func gainDB(at time: Double) -> Double {
        Self.db(forPosition: position(at: time))
    }

    /// The volume change at `time` as a multiplier.
    func gain(at time: Double) -> Double {
        guard !keyframes.isEmpty else { return 1 }
        let position = position(at: time)
        return pow(position * sqrt(pow(10, Self.maxDB / 20)), 2)
    }

    /// Between keyframe `index` and the next: straight, or a curve where either end is smooth.
    private func segmentPosition(_ index: Int, at time: Double) -> Double {
        let a = keyframes[index], b = keyframes[index + 1]
        let span = b.time - a.time
        let pa = Self.position(forDB: a.gainDB), pb = Self.position(forDB: b.gainDB)
        guard span > 0 else { return pb }
        let s = (time - a.time) / span
        let slope = (pb - pa) / span
        guard a.isSmooth || b.isSmooth else { return pa + (pb - pa) * s }
        // A spline keyframe's curve blends from the straight line (0) to the full ease (1).
        let m0 = a.isSmooth ? slope + (smoothSlope(at: index) - slope) * min(1, max(0, a.curve)) : slope
        let m1 = b.isSmooth ? slope + (smoothSlope(at: index + 1) - slope) * min(1, max(0, b.curve)) : slope
        // Cubic Hermite curve.
        let s2 = s * s, s3 = s2 * s
        let value = (2 * s3 - 3 * s2 + 1) * pa + (s3 - 2 * s2 + s) * span * m0
            + (-2 * s3 + 3 * s2) * pb + (s3 - s2) * span * m1
        return min(1, max(0, value))
    }

    /// How steep the curve is through a smooth keyframe: flat at a peak, a dip, or an end, and
    /// otherwise following its neighbors without overshooting them.
    private func smoothSlope(at index: Int) -> Double {
        guard index > 0, index < keyframes.count - 1 else { return 0 }
        let before = keyframes[index - 1], here = keyframes[index], after = keyframes[index + 1]
        let p0 = Self.position(forDB: before.gainDB), p1 = Self.position(forDB: here.gainDB),
            p2 = Self.position(forDB: after.gainDB)
        guard here.time > before.time, after.time > here.time else { return 0 }
        let left = (p1 - p0) / (here.time - before.time), right = (p2 - p1) / (after.time - here.time)
        guard left * right > 0 else { return 0 }
        return 2 * left * right / (left + right)
    }

    // MARK: Editing

    /// Adds a keyframe at `time` at the volume already there, and returns its id. A keyframe
    /// already at that time is returned instead.
    @discardableResult
    mutating func addKeyframe(at time: Double, minimumGap: Double = 0, smooth: Bool = true) -> UUID {
        if let existing = keyframes.first(where: { abs($0.time - time) <= max(minimumGap, 1e-9) }) {
            return existing.id
        }
        let db = gainDB(at: time)
        let key = Keyframe(time: time, gainDB: db.isFinite ? db : Self.minDB, isSmooth: smooth)
        keyframes.append(key)
        keyframes.sort { $0.time < $1.time }
        return key.id
    }

    func keyframe(_ id: UUID) -> Keyframe? { keyframes.first { $0.id == id } }

    /// The times a keyframe can move between: its neighbors (a hair inside them), or the clip's ends.
    func movableRange(of id: UUID, duration: Double, gap: Double) -> ClosedRange<Double> {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return 0...duration }
        let low = index > 0 ? keyframes[index - 1].time + gap : 0
        let high = index < keyframes.count - 1 ? keyframes[index + 1].time - gap : duration
        return low...max(low, high)
    }

    /// Moves a keyframe. It keeps its place in the order (see `movableRange`).
    mutating func move(_ id: UUID, to time: Double, gainDB: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].time = time
        keyframes[index].gainDB = min(Self.maxDB, gainDB.isFinite ? max(Self.minDB, gainDB) : Self.minDB)
        keyframes.sort { $0.time < $1.time }
    }

    mutating func setSmooth(_ id: UUID, _ smooth: Bool) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].isSmooth = smooth
    }

    mutating func setCurve(_ id: UUID, _ curve: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].curve = min(1, max(0, curve))
    }

    mutating func remove(_ id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        keyframes.removeAll()
    }
}
