import SwiftUI

struct ClipDetailView: View {
    @Environment(ProjectStore.self) private var store
    let clip: Clip
    @State private var controller = ClipPlayerController()
    @State private var keyMonitor = PlaybackKeyMonitor()

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
        .onAppear { keyMonitor.start(controller) }
        .onDisappear {
            keyMonitor.stop()
            controller.pause()
        }
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

/// Filmstrip scrubber with the in/out range highlighted.
///
/// Click or drag to move the playhead. When a range is marked, drag the yellow
/// handles to move the in and out points. Hold Shift while dragging for fine control,
/// or Shift-Command for extra-fine control.
private struct Scrubber: View {
    let controller: ClipPlayerController
    let clip: Clip

    private enum Target { case playhead, inPoint, outPoint }

    /// Where a drag started, so the speed can change mid-drag without jumping.
    private struct DragAnchor {
        var target: Target
        var value: Double
        var x: CGFloat
        var speed: Double
        var latest: Double
    }

    @State private var anchor: DragAnchor?

    private let height: CGFloat = 40
    private let handleWidth: CGFloat = 12
    /// How fast the point follows the mouse: Shift for 1/10 speed, Shift-Command for 1/50.
    private static func dragSpeed(for flags: NSEvent.ModifierFlags) -> Double {
        if flags.contains([.shift, .command]) { return 0.02 }
        if flags.contains(.shift) { return 0.1 }
        return 1
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = max(controller.duration, 0.001)
            let x = { (seconds: Double) in CGFloat(seconds / duration) * width }
            let range = clip.markedRange
            let inX = x(range.lowerBound), outX = x(range.upperBound)

            ZStack(alignment: .leading) {
                filmstrip(width: width)

                if clip.hasMarks {
                    // Dim everything outside the marked range.
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: inX)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, width - outX))
                        .offset(x: outX)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: max(handleWidth * 2, outX - inX))
                        .offset(x: inX)
                        .allowsHitTesting(false)
                }

                // Playhead
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .shadow(radius: 2)
                    .frame(width: 3, height: height + 8)
                    .offset(x: min(max(0, x(controller.currentTime) - 1.5), width - 3))
                    .allowsHitTesting(false)

                if clip.hasMarks {
                    handle(edge: .leading)
                        .offset(x: min(inX, width - handleWidth))
                        .gesture(drag(.inPoint, width: width, duration: duration))
                    handle(edge: .trailing)
                        .offset(x: max(0, outX - handleWidth))
                        .gesture(drag(.outPoint, width: width, duration: duration))
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(drag(.playhead, width: width, duration: duration))
        }
        .frame(height: height)
        .coordinateSpace(.named("scrubber"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playhead")
        .accessibilityValue(controller.clock.timecode(seconds: controller.currentTime))
        .accessibilityAdjustableAction { direction in
            controller.step(by: direction == .increment ? 1 : -1)
        }
    }

    private func handle(edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 4 : 0, bottomLeadingRadius: edge == .leading ? 4 : 0,
            bottomTrailingRadius: edge == .trailing ? 4 : 0, topTrailingRadius: edge == .trailing ? 4 : 0
        )
        .fill(Color.yellow)
        .overlay {
            Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle().inset(by: -4))
        .pointerStyle(.columnResize)
        .help(edge == .leading ? "Drag to move the in point. Hold Shift for fine control, Shift-Command for extra fine." : "Drag to move the out point. Hold Shift for fine control, Shift-Command for extra fine.")
        .accessibilityLabel(edge == .leading ? "In point" : "Out point")
    }

    private func drag(_ target: Target, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: target == .playhead ? 0 : 1, coordinateSpace: .named("scrubber"))
            .onChanged { value in
                let x = value.location.x
                let speed = Self.dragSpeed(for: NSEvent.modifierFlags)

                if anchor == nil {
                    let start: Double = switch target {
                    case .playhead:
                        // A plain click jumps to the spot; a Shift-click keeps the playhead where it is.
                        speed < 1 ? controller.currentTime : Double(min(max(0, x / width), 1)) * duration
                    case .inPoint: clip.markedRange.lowerBound
                    case .outPoint: clip.markedRange.upperBound
                    }
                    anchor = DragAnchor(target: target, value: start, x: x, speed: speed, latest: start)
                } else if anchor?.speed != speed, let current = anchor {
                    // Modifier keys changed mid-drag: continue from here at the new speed.
                    anchor = DragAnchor(target: target, value: current.latest, x: x, speed: speed, latest: current.latest)
                }

                guard var current = anchor else { return }
                let seconds = min(max(0, current.value + Double((x - current.x) / width) * duration * speed), duration)
                current.latest = seconds
                anchor = current

                switch target {
                case .playhead:
                    controller.pause()
                    controller.seek(to: seconds)
                case .inPoint:
                    controller.dragIn(to: seconds)
                case .outPoint:
                    controller.dragOut(to: seconds)
                }
            }
            .onEnded { _ in anchor = nil }
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

// MARK: Keyboard

/// Handles the single-key playback shortcuts while a clip is showing.
///
/// Menu shortcuts alone aren't enough: the sidebar list swallows Space (and
/// type-to-select letters) before the menu sees them.
@MainActor
final class PlaybackKeyMonitor {
    private var monitor: Any?

    func start(_ controller: ClipPlayerController) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak controller] event in
            let handled = MainActor.assumeIsolated {
                // Only in the main window, and never while typing in a text field.
                guard let controller, let window = event.window, window == NSApp.mainWindow,
                      !(window.firstResponder is NSText) else { return false }
                return Self.perform(event, on: controller)
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Runs the shortcut for `event`, if it is one. Returns whether it was handled.
    static func perform(_ event: NSEvent, on controller: ClipPlayerController) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased()

        switch (event.keyCode, key, flags) {
        case (49, _, []):  // Space
            if !event.isARepeat { controller.togglePlayPause() }
        case (123, _, []): controller.step(by: -1)  // Left arrow
        case (124, _, []): controller.step(by: 1)   // Right arrow
        case (_, "i", []): controller.markIn()
        case (_, "o", []): controller.markOut()
        case (_, "i", .shift): controller.goToIn()
        case (_, "o", .shift): controller.goToOut()
        case (_, "x", .option), (_, "≈", .option): controller.clearInOut()
        default: return false
        }
        return true
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
