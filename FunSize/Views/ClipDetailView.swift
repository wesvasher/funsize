import SwiftUI

struct ClipDetailView: View {
    @Environment(ProjectStore.self) private var store
    let clip: Clip
    @State private var controller = ClipPlayerController()

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: controller.player, showsControls: false)
                .background(.black)
                .overlay {
                    // Click the picture to play or pause.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.togglePlayPause() }
                }

            Divider()

            TransportBar(controller: controller, clip: clip) {
                store.addToTimeline([clip])
            }
        }
        .focusedSceneValue(\.clipPlayer, controller)
        .onChange(of: clip.id, initial: true) {
            controller.load(clip)
        }
        .onDisappear { controller.pause() }
    }
}

/// Always-visible controls under the clip: scrubber, timecode, frame counter, and in/out.
private struct TransportBar: View {
    let controller: ClipPlayerController
    let clip: Clip
    let addToTimeline: () -> Void

    var body: some View {
        let clock = controller.clock

        VStack(spacing: 10) {
            Scrubber(controller: controller, clip: clip)

            HStack(spacing: 16) {
                HStack(spacing: 2) {
                    transportButton("Go to In", "arrow.left.to.line", help: "Go to in point (⇧I)", action: controller.goToIn)
                    transportButton("Previous Frame", "backward.frame.fill", help: "Previous frame (←)") { controller.step(by: -1) }
                    transportButton(controller.isPlaying ? "Pause" : "Play",
                                    controller.isPlaying ? "pause.fill" : "play.fill",
                                    help: "Play or pause (Space)", action: controller.togglePlayPause)
                        .font(.title2)
                    transportButton("Next Frame", "forward.frame.fill", help: "Next frame (→)") { controller.step(by: 1) }
                    transportButton("Go to Out", "arrow.right.to.line", help: "Go to out point (⇧O)", action: controller.goToOut)
                }

                Divider().frame(height: 28)

                Readout(title: "Timecode",
                        value: "\(clock.timecode(seconds: controller.currentTime)) / \(clock.timecode(frames: controller.frameCount))")
                Readout(title: "Frame",
                        value: "\(controller.currentFrameNumber.formatted()) / \(controller.frameCount.formatted())")
                Readout(title: "Frame Rate", value: String(format: "%.3g fps", clock.fps))

                Spacer(minLength: 0)
            }

            HStack(spacing: 16) {
                Button("Mark In", systemImage: "chevron.left.to.line", action: controller.markIn)
                    .help("Mark in point (I)")
                Button("Mark Out", systemImage: "chevron.right.to.line", action: controller.markOut)
                    .help("Mark out point (O)")

                Readout(title: "In", value: clip.inPoint.map { clock.timecode(seconds: $0) } ?? "—")
                Readout(title: "Out", value: clip.outPoint.map { clock.timecode(frames: max(0, clock.frameIndex(at: $0) - 1)) } ?? "—")
                Readout(title: "Marked Length", value: markedLength(clock))

                if clip.hasMarks {
                    Button("Clear", systemImage: "xmark.circle.fill", action: controller.clearInOut)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear in and out (⌥X)")
                }

                Spacer(minLength: 0)

                Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle", action: addToTimeline)
                    .help(clip.hasMarks ? "Add the marked range to the timeline" : "Add the clip to the timeline")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func markedLength(_ clock: FrameClock) -> String {
        let range = clip.markedRange
        let frames = clock.frameIndex(at: range.upperBound) - clock.frameIndex(at: range.lowerBound)
        return clock.timecode(frames: max(0, frames))
    }

    private func transportButton(_ title: String, _ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: image, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help(help)
    }
}

private struct Readout: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .fixedSize()
    }
}

/// Filmstrip scrubber with the in/out range highlighted. Click or drag to move the playhead.
private struct Scrubber: View {
    let controller: ClipPlayerController
    let clip: Clip

    private let height: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = max(controller.duration, 0.001)
            let x = { (seconds: Double) in CGFloat(seconds / duration) * width }
            let range = clip.markedRange

            ZStack(alignment: .leading) {
                filmstrip(width: width)

                // Dim everything outside the marked range.
                if clip.hasMarks {
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: x(range.lowerBound))
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, width - x(range.upperBound)))
                        .offset(x: x(range.upperBound))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: max(6, x(range.upperBound) - x(range.lowerBound)))
                        .offset(x: x(range.lowerBound))
                }

                // Playhead
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .shadow(radius: 2)
                    .frame(width: 3, height: height + 8)
                    .offset(x: min(max(0, x(controller.currentTime) - 1.5), width - 3))
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.pause()
                        controller.seek(to: Double(min(max(0, value.location.x / width), 1)) * duration)
                    }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(controller.clock.timecode(seconds: controller.currentTime))
        .accessibilityAdjustableAction { direction in
            controller.step(by: direction == .increment ? 1 : -1)
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        let count = max(1, Int(width / 64))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                ClipThumbnail(clip: clip, time: controller.duration * (Double(index) + 0.5) / Double(count))
                    .frame(width: width / CGFloat(count), height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15))
        }
    }
}

// MARK: Playback menu

extension FocusedValues {
    @Entry var clipPlayer: ClipPlayerController?
}

/// Playback menu. Its single-key shortcuts (Space, I, O, arrows) work while a clip is showing.
struct PlaybackCommands: Commands {
    @FocusedValue(\.clipPlayer) private var player

    var body: some Commands {
        CommandMenu("Playback") {
            Group {
                Button(player?.isPlaying == true ? "Pause" : "Play") { player?.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button("Previous Frame") { player?.step(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Frame") { player?.step(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Mark In") { player?.markIn() }
                    .keyboardShortcut("i", modifiers: [])
                Button("Mark Out") { player?.markOut() }
                    .keyboardShortcut("o", modifiers: [])
                Button("Clear In and Out") { player?.clearInOut() }
                    .keyboardShortcut("x", modifiers: .option)
                Divider()
                Button("Go to In") { player?.goToIn() }
                    .keyboardShortcut("i", modifiers: .shift)
                Button("Go to Out") { player?.goToOut() }
                    .keyboardShortcut("o", modifiers: .shift)
            }
            .disabled(player == nil)
        }
    }
}
