import SwiftUI

/// The loudness meter's scale: −40 to 0 LUFS. Both bars and the numbers under them share it,
/// and a line marks the timeline's target, so lining clips up is a matter of reaching it.
enum LoudnessMeter {
    static let range = -40.0...0.0

    static func fraction(_ lufs: Double) -> Double {
        min(1, max(0, (lufs - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

/// How loud the clip is right now, while it plays.
struct LiveLoudnessBar: View {
    let audio: TimelineAudio
    /// Where the clip plays on the timeline (seconds). Sound from elsewhere isn't shown.
    let span: Range<Double>
    let target: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let level = audio.level.flatMap { span.contains($0.time) ? $0 : nil }
            LoudnessBar(value: level?.momentary, original: nil, target: target, isLive: true)
        }
    }
}

/// The numbers under the bars.
struct LoudnessScale: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach([-40, -30, -20, -10, 0], id: \.self) { mark in
                Text(mark == 0 ? "0" : "−\(-mark)")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: LoudnessMeter.fraction(Double(mark)) * geometry.size.width, y: geometry.size.height / 2)
            }
        }
        .frame(height: 10)
    }
}

/// One horizontal bar: filled up to `value` LUFS.
struct LoudnessBar: View {
    let value: Double?
    let original: Double?
    let target: Double?
    var isLive = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let value, value > LoudnessMeter.range.lowerBound {
                    Capsule()
                        .fill(color(for: value).gradient)
                        .frame(width: max(4, LoudnessMeter.fraction(value) * width))
                        .animation(isLive ? .linear(duration: 1.0 / 30) : .default, value: value)
                }
                if let original {
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: LoudnessMeter.fraction(original) * width - 1)
                }
                if let target {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: LoudnessMeter.fraction(target) * width - 1)
                }
            }
        }
        .frame(height: 8)
    }

    /// Green near the target, yellow when well above it, red near full scale.
    private func color(for value: Double) -> Color {
        if value > -6 { return .red }
        if let target, value > target + 3 { return .yellow }
        return .green
    }
}

extension Double {
    /// "−16.0" with a real minus sign.
    var loudnessText: String {
        String(format: "%.1f", self).replacingOccurrences(of: "-", with: "−")
    }

    /// "+7.4 dB", "−3.0 dB", or "0 dB".
    var decibelChangeText: String {
        let rounded = (self * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return (rounded > 0 ? "+" : "") + rounded.loudnessText + " dB"
    }
}

/// A small stereo level meter for the timeline's output: one thin bar per channel showing
/// the loudest sample of the last moment, −60 to 0 dB (green, yellow above −12, red above −3).
struct OutputLevelMeter: View {
    let audio: TimelineAudio

    private static let floor = -60.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let peaks = channels(audio.level?.peaks ?? [])
            VStack(spacing: 2) {
                ForEach(peaks.indices, id: \.self) { index in
                    bar(peaks[index])
                }
            }
        }
        .frame(width: 80)
        .help("The timeline's sound level as it plays (left and right)")
    }

    /// Always two bars: mono shows in both, more channels show the first two.
    private func channels(_ peaks: [Double]) -> [Double] {
        switch peaks.count {
        case 0: [-.infinity, -.infinity]
        case 1: [peaks[0], peaks[0]]
        default: Array(peaks.prefix(2))
        }
    }

    private func bar(_ decibels: Double) -> some View {
        GeometryReader { geometry in
            let fraction = decibels.isFinite ? min(1, max(0, 1 - decibels / Self.floor)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.78),
                        .init(color: .yellow, location: 0.8),   // −12 dB
                        .init(color: .yellow, location: 0.93),
                        .init(color: .red, location: 0.95),     // −3 dB
                    ], startPoint: .leading, endPoint: .trailing))
                    // The gradient spans the whole bar; the mask shows the part up to the level.
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fraction * geometry.size.width)
                    }
                    .animation(.linear(duration: 1.0 / 30), value: fraction)
            }
        }
        .frame(height: 4)
    }
}
