import SwiftUI

/// The master volume, in the bar above the video: mute, a slider, and a button back to the monitoring level.
struct MonitorVolumeControl: View {
    @Bindable private var volume = MonitorVolume.shared

    var body: some View {
        HStack(spacing: 6) {
            Button(volume.isMuted ? "Unmute" : "Mute", systemImage: speakerSymbol) {
                volume.isMuted.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 22)
            .help(volume.isMuted ? "Unmute" : "Mute")

            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .contentTransition(.numericText(value: volume.decibels))

            Slider(value: $volume.decibels, in: MonitorVolume.range) {
                Text("Volume")
            } onEditingChanged: { editing in
                if editing { volume.isMuted = false }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 90)
            .help("Volume. For listening only; exports aren't affected.")

            Button("Monitoring Level", systemImage: "ear") {
                withAnimation { volume.setMonitoringLevel() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(volume.isAtMonitoringLevel ? Color.accentColor : .secondary)
            .help("Monitoring level (0 dB): hear the sound exactly as it will export")
        }
    }

    private var readout: String {
        if volume.isMuted { return "Muted" }
        if volume.decibels <= MonitorVolume.range.lowerBound { return "Off" }
        return volume.decibels.rounded() == 0 ? "0 dB" : "\(Int(volume.decibels.rounded())) dB".replacingOccurrences(of: "-", with: "−")
    }

    private var speakerSymbol: String {
        if volume.isMuted || volume.decibels <= MonitorVolume.range.lowerBound { return "speaker.slash.fill" }
        return "speaker.wave.3.fill"
    }
}
