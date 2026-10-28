import SwiftUI

/// The clip's sound under the filmstrip: each column's loudest moment, mirrored around the middle.
/// Only the drawn part of the strip (`drawn`, out of `contentWidth`) is drawn.
struct WaveformView: View {
    let waveform: Waveform?
    let isReading: Bool
    let contentWidth: CGFloat
    let drawn: ClosedRange<CGFloat>
    /// The volume keyframes: the waveform shows the sound after them.
    var volume = VolumeEnvelope()
    var duration: Double = 0
    /// 0 draws it square and unframed, to sit inside something else's frame (a timeline clip).
    var cornerRadius: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            guard let waveform, !waveform.peaks.isEmpty, size.width > 0, contentWidth > 0 else { return }
            let columns = Int(size.width.rounded(.up))
            let count = waveform.peaks.count
            let perPoint = Double(count) / Double(contentWidth)
            let middle = size.height / 2
            var path = Path()
            for column in 0..<columns {
                let x = Double(drawn.lowerBound) + Double(column)
                let first = min(count - 1, Int(x * perPoint))
                let last = max(first + 1, min(count, Int((x + 1) * perPoint)))
                var level: Float = 0
                for index in first..<last { level = max(level, waveform.height(at: index)) }
                if !volume.isEmpty, level > 0, duration > 0 {
                    // Heights are in decibels above the floor, so a volume change shifts them evenly.
                    let gain = volume.gainDB(at: (x + 0.5) / Double(contentWidth) * duration)
                    level = gain.isFinite ? min(1, max(0, level - Float(gain) / Waveform.floorDB)) : 0
                }
                let half = max(0.5, CGFloat(level) * (middle - 1))
                path.addRect(CGRect(x: CGFloat(column), y: middle - half, width: 1, height: half * 2))
            }
            // Strongest at the middle line, fading toward the peaks, so it reads lighter than a solid block.
            let shading = Gradient(stops: [
                .init(color: .accentColor.opacity(0.2), location: 0),
                .init(color: .accentColor.opacity(0.65), location: 0.5),
                .init(color: .accentColor.opacity(0.2), location: 1),
            ])
            context.fill(path, with: .linearGradient(shading, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if cornerRadius > 0 {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.15))
            }
            if isReading { ProgressView().controlSize(.mini) }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

extension Clip {
    /// Reads the waveform the first time it's needed (it's kept on the clip after that).
    func readWaveform() async {
        guard hasAudio, !isWaveformRead, isLoaded else { return }
        let url = url, duration = duration
        let waveform = try? await Task.detached(priority: .utility) {
            try await Waveform.read(url: url, duration: duration)
        }.value
        guard !Task.isCancelled, !isWaveformRead else { return }
        self.waveform = waveform
        isWaveformRead = true
    }
}
