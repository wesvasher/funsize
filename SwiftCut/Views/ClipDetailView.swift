import SwiftUI

/// Shows a source video, or a subclip of one. For a source video, In and Out mark the range
/// for the next subclip; for a subclip, they change the subclip's range.
struct ClipDetailView: View {
    @Environment(ProjectStore.self) private var store
    let clip: Clip
    var subclip: Subclip? = nil
    @State private var controller = ClipPlayerController()
    @State private var keyMonitor = PlaybackKeyMonitor()
    /// Identifies this view as the full-screen source.
    @State private var sourceID = UUID()
    @AppStorage("showClipInspector") private var isShowingInspector = true
    /// The viewer's zoom stays the same from clip to clip; the picture goes back to centered.
    @State private var zoom = ViewerZoom.fit
    @State private var pan = CGSize.zero
    /// The video toolbar's Quality menu, kept from clip to clip and between launches.
    @AppStorage("clipPreviewQuality") private var quality = PreviewQuality.full
    @State private var toast: Toast?
    /// The part of the picture on screen, and its size there in pixels, for Export Images.
    @State private var visibleView = (fraction: CGRect(x: 0, y: 0, width: 1, height: 1), pixels: CGSize.zero)
    @State private var isExportingImages = false
    @State private var isMakingSource = false

    /// The inspector, hidden while both sidebars are hidden (⌘.). Showing it by hand
    /// brings the left sidebar back too.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { isShowingInspector && !store.sidebarsHidden },
            set: { show in
                if show, store.sidebarsHidden { store.sidebarsHidden = false }
                isShowingInspector = show
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoToolbar(pictureSize: clip.outputSize, zoom: $zoom, quality: $quality,
                         qualityHelp: "Preview quality. Lower settings run the clip's effects, color, and framing on a smaller picture, so they play smoothly. Clips without any play as is. Exports and copied frames are always full quality.",
                         canCopy: clip.hasVideo,
                         isExporting: isExportingImages, copyFrame: copyFrame, exportImages: exportImages)

            Divider()

            ZoomableVideoView(controller: controller,
                              pictureSize: clip.outputSize == .zero ? clip.displaySize : clip.outputSize,
                              zoom: zoom, pan: $pan, zoomToFit: { zoom = .fit },
                              reportView: { visibleView = ($0, $1) })
                .toast($toast)

            Divider()

            TransportBar(controller: controller, clip: clip, subclip: subclip,
                         addSubclip: { store.addSubclip(from: clip) },
                         addToTimeline: { store.addToTimeline([subclip.map { .subclip($0.id) } ?? .clip(clip.id)]) },
                         makeSource: { isMakingSource = true })
        }
        .sheet(isPresented: $isMakingSource) {
            NewSourceSheet(clip: clip, controller: controller, subclip: subclip)
        }
        // No minimum size: a view beside an inspector that demands a minimum width makes the
        // split view re-layout in a loop until AppKit aborts (macOS 27). Narrow windows clip instead.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .focusedSceneValue(\.clipPlayer, controller)
        .spaceBarPlaysAndPauses { controller.togglePlayPause() }
        .onChange(of: [ObjectIdentifier(clip), subclip.map(ObjectIdentifier.init)], initial: true) {
            controller.load(clip, subclip: subclip)
            pan = .zero
            let controller = controller, title = subclip?.name ?? clip.name
            store.setFullScreenSource(.init(owner: sourceID) {
                FullScreenPlayer.present(player: controller.player, title: title) {
                    controller.play()
                } onClose: {
                    controller.pause()
                }
            })
        }
        .onChange(of: subclip?.volume ?? clip.volume) { controller.updateVolume() }
        .onChange(of: clip.enhanceSettings.layout) { controller.updateLayout() }
        .onChange(of: clip.showCaptions) {
            Task { await controller.updateCaptions() }
        }
        .onChange(of: clip.enhanceSettings.colorLook) {
            controller.updateColor()
        }
        // The LUT and grade aren't part of the key: the preview follows them live.
        .onChange(of: quality, initial: true) { controller.previewQuality = quality }
        .task(id: EffectsKey(id: clip.id, settings: clip.enhanceSettings.structure, quality: quality)) {
            // Wait a moment so dragging a slider doesn't rebuild the preview on every tick.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await controller.applyEffects()
        }
        .inspector(isPresented: inspectorShown) {
            ClipInspectorView(clip: clip, subclip: subclip, controller: controller) {
                store.selection = [.clip(clip.id)]
            }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .inspectorColumnWidth(300)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") {
                    inspectorShown.wrappedValue.toggle()
                }
                .help(inspectorShown.wrappedValue ? "Hide the inspector" : "Show the inspector")
            }
        }
        .onAppear { keyMonitor.start(controller) }
        .onDisappear {
            keyMonitor.stop()
            controller.pause()
            store.clearFullScreenSource(owner: sourceID)
        }
    }
}

extension ClipDetailView {
    /// Copies the frame on screen and says so in a toast.
    private func copyFrame() {
        let describe = "Frame \(controller.currentFrameNumber.formatted()) (\(controller.clock.timecode(seconds: controller.currentTime)))"
        let suffix = controller.isShowingOriginal ? ", without effects." : ", as shown in the viewer."
        Task {
            toast = await VideoFrameActions.copy(grab: controller.currentFrameImage, describe: describe, suffix: suffix)
        }
    }

    /// Saves the whole frame and the part in view as PNGs next to the project.
    private func exportImages() {
        let baseName = "\(subclip?.name ?? clip.name) Frame \(controller.currentFrameNumber)"
        let view = visibleView, zoomTitle = zoom.title
        isExportingImages = true
        Task {
            defer { isExportingImages = false }
            if let result = await VideoFrameActions.exportImages(grab: controller.currentFrameImage, baseName: baseName,
                                                                 view: view, zoomTitle: zoomTitle, store: store) {
                toast = result
            }
        }
    }
}

/// Changes whenever the preview needs rebuilding with different effects.
private struct EffectsKey: Hashable {
    let id: UUID
    let settings: EnhanceSettings
    let quality: PreviewQuality
}

/// Always-visible controls under the clip: scrubber, timecode, frame counter, and in/out.
private struct TransportBar: View {
    let controller: ClipPlayerController
    let clip: Clip
    let subclip: Subclip?
    let addSubclip: () -> Void
    let addToTimeline: () -> Void
    let makeSource: () -> Void

    var body: some View {
        let clock = controller.clock

        VStack(spacing: 10) {
            Scrubber(controller: controller, clip: clip, zoom: $zoom, maxZoom: $maxZoom)

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
                PlaybackSpeedMenu(controller: controller)
                LoopPicker(controller: controller)

                Spacer(minLength: 0)

                zoomControls
            }

            HStack(spacing: 16) {
                Button("Mark In", systemImage: "chevron.left.to.line", action: controller.markIn)
                    .help("Mark in point (I)")
                Button("Mark Out", systemImage: "chevron.right.to.line", action: controller.markOut)
                    .help("Mark out point (O)")

                HStack(spacing: 6) {
                    Readout(title: "In", value: controller.inPoint.map { clock.timecode(seconds: $0) } ?? "—",
                            detail: "Frame \(inFrame(clock).formatted())")
                    nudgeButtons(point: "in point", nudge: controller.nudgeIn)
                }
                HStack(spacing: 6) {
                    Readout(title: "Out", value: controller.outPoint.map { clock.timecode(frames: max(0, clock.frameIndex(at: $0) - 1)) } ?? "—",
                            detail: "Frame \(outFrame(clock).formatted())")
                    nudgeButtons(point: "out point", nudge: controller.nudgeOut)
                }
                Readout(title: subclip == nil ? "Marked Length" : "Subclip Length", value: markedLength(clock),
                        detail: "\(markedFrames(clock).formatted()) frames")

                if subclip == nil, clip.hasMarks {
                    Button("Clear", systemImage: "xmark.circle.fill", action: controller.clearInOut)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear in and out (⌥X)")
                }

                Spacer(minLength: 0)

                Button("New Source Video…", systemImage: "film.stack", action: makeSource)
                    .disabled(!clip.isLoaded || !clip.hasVideo)
                    .help("Save this clip, or its in-to-out range, as a new video file in the project folder and add it to Source Videos. Choose which settings to bake in or carry over.")

                if subclip == nil, clip.hasMarks {
                    // The marked range becomes a new subclip on the timeline; the source isn't changed.
                    Button("Add Subclip", systemImage: "scissors", action: addSubclip)
                        .buttonStyle(.borderedProminent)
                        .help("Make a subclip from the marked range and add it to the timeline. The source video isn't changed.")
                } else {
                    Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle", action: addToTimeline)
                        .help(subclip == nil
                              ? "Add the whole source video to the timeline. To use part of it, mark in and out."
                              : "Add this subclip to the timeline")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .onModifierKeysChanged(mask: [.shift, .option]) { _, keys in nudgeKeys = keys }
    }

    // MARK: Filmstrip zoom

    @State private var zoom = 1.0
    @State private var maxZoom = 1.0
    private let zoomStep = 1.5

    /// Zoom out, a slider, zoom in, and zoom to fit, like the timeline's.
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / zoomStep) }
                .help("Zoom out")
                .disabled(zoom <= 1)
            // Even steps across the range, however long the clip.
            Slider(value: Binding(
                get: { maxZoom > 1 ? log(zoom) / log(maxZoom) : 0 },
                set: { zoom = min(maxZoom, max(1, pow(maxZoom, $0))) }
            ), in: 0...1)
            .frame(width: 110)
            .help("Zoom the filmstrip. Zoom in far enough and each frame shows on its own.")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(maxZoom, zoom * zoomStep) }
                .help("Zoom in")
                .disabled(zoom >= maxZoom)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(maxZoom <= 1)
    }

    /// Shift and Option change how far the nudge buttons move a point.
    @State private var nudgeKeys: EventModifiers = []

    /// Frames per nudge: 1, 10 with Shift, or one second with Option-Shift.
    private func nudgeStep(_ keys: EventModifiers) -> (frames: Int, label: String) {
        if keys.contains(.shift) && keys.contains(.option) { return (controller.clock.timecodeBase, "1s") }
        if keys.contains(.shift) { return (10, "10") }
        return (1, "1")
    }

    /// Small − and + buttons that move the in or out point.
    private func nudgeButtons(point: String, nudge: @escaping (Int) -> Void) -> some View {
        let step = nudgeStep(nudgeKeys)
        return HStack(spacing: 2) {
            ForEach([-1, 1], id: \.self) { direction in
                Button {
                    // Read the keys at the click too, in case they changed without the view hearing.
                    var keys: EventModifiers = []
                    if NSEvent.modifierFlags.contains(.shift) { keys.insert(.shift) }
                    if NSEvent.modifierFlags.contains(.option) { keys.insert(.option) }
                    nudge(direction * nudgeStep(keys).frames)
                } label: {
                    Text((direction < 0 ? "−" : "+") + step.label)
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 22)
                }
                .help("Move the \(point) \(direction < 0 ? "earlier" : "later") by 1 frame. Hold Shift for 10 frames, Option-Shift for 1 second.")
            }
        }
        .controlSize(.mini)
    }

    private func markedFrames(_ clock: FrameClock) -> Int {
        let range = controller.markedRange
        return max(0, clock.frameIndex(at: range.upperBound) - clock.frameIndex(at: range.lowerBound))
    }

    /// One-based numbers of the first and last marked frames.
    private func inFrame(_ clock: FrameClock) -> Int {
        clock.frameIndex(at: controller.markedRange.lowerBound) + 1
    }

    private func outFrame(_ clock: FrameClock) -> Int {
        max(1, min(clock.frameIndex(at: controller.markedRange.upperBound), controller.frameCount))
    }

    private func markedLength(_ clock: FrameClock) -> String {
        clock.timecode(frames: markedFrames(clock))
    }

    private func transportButton(_ title: String, _ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: image, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help(help)
    }
}

/// "100% (59.94 fps)": how fast playback runs, shown with the effective frames per second.
private struct PlaybackSpeedMenu: View {
    @Bindable var controller: ClipPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Playback Speed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Playback Speed", selection: $controller.playbackSpeed) {
                ForEach(ClipPlayerController.playbackSpeeds, id: \.self) { speed in
                    Text(label(for: speed)).tag(speed)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .fixedSize()
            .font(.body.monospacedDigit())
            .help("Playback speed. Doesn't change the clip's frame rate or exports.")
        }
    }

    private func label(for speed: Float) -> String {
        let fps = controller.clock.fps * Double(speed)
        return "\(Int((speed * 100).rounded()))% (\(String(format: "%.4g", fps)) fps)"
    }
}

/// Off, Loop, or Back and Forth: what playback does at the out point. Remembered between clips
/// and launches.
private struct LoopPicker: View {
    let controller: ClipPlayerController
    @AppStorage("clipLoopMode") private var mode = ClipPlayerController.LoopMode.off

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Loop")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Drawn here rather than a segmented Picker: the AppKit segmented control in this
            // bar sent the window into an endless constraints loop (crash) on macOS 27.
            HStack(spacing: 0) {
                ForEach(ClipPlayerController.LoopMode.allCases) { option in
                    segment(option)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Loop")
        }
        .onChange(of: mode, initial: true) { _, mode in controller.loopMode = mode }
    }

    private func segment(_ option: ClipPlayerController.LoopMode) -> some View {
        let isSelected = option == mode
        return Button { mode = option } label: {
            Group {
                if option == .off {
                    Text("Off")
                } else {
                    Image(systemName: Self.image(option))
                }
            }
            .font(.callout)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(minWidth: 22, minHeight: 18)
            .padding(.horizontal, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.help(option))
        .accessibilityLabel(Self.title(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func title(_ mode: ClipPlayerController.LoopMode) -> String {
        switch mode {
        case .off: "Loop Off"
        case .loop: "Loop"
        case .backAndForth: "Back and Forth"
        }
    }

    private static func image(_ mode: ClipPlayerController.LoopMode) -> String {
        switch mode {
        case .off: "arrow.right"
        case .loop: "repeat"
        case .backAndForth: "arrow.left.arrow.right"
        }
    }

    private static func help(_ mode: ClipPlayerController.LoopMode) -> String {
        switch mode {
        case .off: "Loop off: play to the end of the clip and stop"
        case .loop: "Loop: play from in to out, then start again at the in point"
        case .backAndForth: "Back and forth: play from in to out, then backward to the in point, and repeat"
        }
    }
}

private struct Readout: View {
    let title: String
    let value: String
    /// A smaller line underneath, like the frame number.
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
    /// Where the pointer is over the scrubber, if it is.
    @State private var hoverX: CGFloat?

    private let filmHeight: CGFloat = 40
    /// The waveform under the filmstrip (none when the clip has no sound): five times as tall
    /// while editing the volume.
    private var waveformHeight: CGFloat { controller.isEditingVolume ? 170 : 34 }
    private let waveformGap: CGFloat = 3
    private var showsWaveform: Bool { clip.hasAudio }
    /// The whole scrubber: filmstrip, then the waveform.
    private var height: CGFloat { showsWaveform ? filmHeight + waveformGap + waveformHeight : filmHeight }
    /// How wide the grab area over the in and out edges is.
    private let edgeGrabWidth: CGFloat = 12
    /// The yellow border's thickness.
    private let borderWidth: CGFloat = 3
    /// The white handle shown over an edge while it's pointed at or dragged.
    private let edgeHandleWidth: CGFloat = 8
    /// The in or out edge under the pointer, if any.
    @State private var hoveredEdge: Target?
    /// How close to the playhead line counts as pointing at it.
    private let playheadReach: CGFloat = 6
    /// How fast the point follows the mouse: Shift for 1/10 speed, Shift-Command for 1/50.
    private static func dragSpeed(for flags: NSEvent.ModifierFlags) -> Double {
        if flags.contains([.shift, .command]) { return 0.02 }
        if flags.contains(.shift) { return 0.1 }
        return 1
    }

    // MARK: Zoom and scrolling

    /// 1 shows the whole clip; higher numbers zoom in (the strip scrolls sideways).
    @Binding var zoom: Double
    /// How far in the zoom goes for this clip and width (frames up to `maxFrameWidth` wide).
    @Binding var maxZoom: Double
    @State private var viewWidth: CGFloat = 0
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var pinchStartZoom: Double?
    @State private var frames = FrameThumbnails()

    /// Frames this wide or wider are drawn as separate blocks.
    static let frameBlockWidth: CGFloat = 50
    static let maxFrameWidth: CGFloat = 120
    /// Space between frame blocks.
    private let frameGap: CGFloat = 1.5

    private var duration: Double { max(controller.duration, 0.001) }
    private var contentWidth: CGFloat { max(1, viewWidth) * zoom }
    private var frameWidth: CGFloat { contentWidth / CGFloat(max(1, duration * controller.clock.fps)) }
    private func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / duration) * contentWidth }

    /// The part of the strip that's drawn: what's on screen plus half a screen either side.
    /// Everything else is left out, so a zoomed-in hour-long clip stays quick.
    private var drawn: ClosedRange<CGFloat> {
        let low = max(0, scrollX - viewWidth / 2)
        return low...max(low, min(contentWidth, scrollX + viewWidth * 1.5))
    }

    var body: some View {
        VStack(spacing: 6) {
            // Zoomed in: the whole clip in miniature, with the part in view outlined.
            if zoom > 1 {
                navigator
                    .transition(.opacity)
            }
            scroller
        }
        .animation(.easeOut(duration: 0.15), value: zoom > 1)
    }

    private var navigator: some View {
        let range = controller.markedRange
        return StripNavigator(
            contentWidth: contentWidth,
            visible: scrollX...(scrollX + viewWidth),
            playheadX: x(controller.currentTime),
            marked: controller.hasMarks ? x(range.lowerBound)...x(range.upperBound) : nil,
            scroll: { left in
                scrollX = left
                scrollPosition.scrollTo(x: left)
            },
            close: { zoom = 1 }
        ) { width in
            // Thumbnails along the whole clip.
            let count = max(1, Int(width / 36))
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let time = (Double(index) + 0.5) / Double(count) * duration
                    FrameBlock(image: clip.thumbnail(near: time), cornerRadius: 0, outlined: false)
                        .frame(width: width / CGFloat(count))
                }
            }
        }
    }

    private var scroller: some View {
        ScrollView(.horizontal) {
            strip
                .frame(width: contentWidth, height: height)
                .coordinateSpace(.named("scrubber"))
                // Room for the playhead to stick out above and below.
                .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .scrollDisabled(zoom <= 1)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in scrollX = offset }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .frame(height: height + 8)
        .padding(.vertical, -4)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStartZoom ?? zoom
                    pinchStartZoom = start
                    zoom = min(maxZoom, max(1, start * value.magnification))
                }
                .onEnded { _ in pinchStartZoom = nil }
        )
        .onChange(of: zoom) { old, new in keepInPlace(from: old, to: new) }
        .onChange(of: controller.currentTime) { _, time in follow(time) }
        .onChange(of: "\(clip.id) \(controller.clock.fps)", initial: true) {
            frames.use(url: clip.url, fps: controller.clock.fps)
        }
        .onChange(of: clip.id) {
            zoom = 1
            scrollX = 0
            scrollPosition.scrollTo(x: 0)
        }
        .onChange(of: [viewWidth, CGFloat(controller.frameCount)], initial: true) {
            maxZoom = max(1, CGFloat(controller.frameCount) * Self.maxFrameWidth / max(1, viewWidth))
            if zoom > maxZoom { zoom = maxZoom }
        }
        .onChange(of: wantedFrames, initial: true) { _, wanted in frames.want(wanted) }
        .task(id: "\(clip.id) \(clip.isLoaded)") { await clip.readWaveform() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playhead")
        .accessibilityValue(controller.clock.timecode(seconds: controller.currentTime))
        .accessibilityAdjustableAction { direction in
            controller.step(by: direction == .increment ? 1 : -1)
        }
    }

    /// Keeps the playhead (or, if it's off screen, the middle) at the same spot while zooming.
    private func keepInPlace(from old: Double, to new: Double) {
        guard viewWidth > 0, old > 0 else { return }
        let oldWidth = viewWidth * old, newWidth = viewWidth * new
        let playheadX = CGFloat(controller.currentTime / duration) * oldWidth
        let onScreen = playheadX >= scrollX && playheadX <= scrollX + viewWidth
        let screenX = onScreen ? playheadX - scrollX : viewWidth / 2
        let fraction = (scrollX + screenX) / oldWidth
        let target = min(max(0, fraction * newWidth - screenX), max(0, newWidth - viewWidth))
        scrollX = target
        // After the strip has its new width.
        DispatchQueue.main.async { scrollPosition.scrollTo(x: target) }
    }

    /// Scrolls to keep the playhead in view: a page at a time while playing, centered otherwise.
    /// Not while dragging, or the strip would run away under the mouse.
    private func follow(_ time: Double) {
        guard zoom > 1, anchor == nil, viewWidth > 0 else { return }
        let playheadX = x(time)
        guard playheadX < scrollX + 8 || playheadX > scrollX + viewWidth - 8 else { return }
        // While playing, page ahead in the direction of play.
        let target = !controller.isPlaying ? playheadX - viewWidth / 2
            : controller.isPlayingBackward ? playheadX - viewWidth * 0.9 : playheadX - viewWidth * 0.1
        let clamped = min(max(0, target), max(0, contentWidth - viewWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Frames to read pictures for, middle of the screen first. None at the fitted zoom,
    /// which uses the clip's own thumbnails.
    private var wantedFrames: [Int] {
        guard zoom > 1, viewWidth > 0 else { return [] }
        let middle = scrollX + viewWidth / 2
        let positions: [CGFloat]
        if frameWidth >= Self.frameBlockWidth {
            let first = max(0, Int(scrollX / frameWidth) - 2)
            let last = min(controller.frameCount - 1, Int((scrollX + viewWidth) / frameWidth) + 2)
            guard first <= last else { return [] }
            positions = (first...last).map { (CGFloat($0) + 0.5) * frameWidth }
        } else {
            positions = tiles(in: scrollX...(scrollX + viewWidth)).map { $0.x + $0.width / 2 }
        }
        return positions
            .sorted { abs($0 - middle) < abs($1 - middle) }
            .map { min(controller.frameCount - 1, max(0, Int($0 / frameWidth))) }
    }

    // MARK: Drawing

    private var strip: some View {
        let range = controller.markedRange
        let inX = x(range.lowerBound), outX = x(range.upperBound)
        let width = contentWidth
        let drawn = drawn

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: waveformGap) {
                filmstrip
                if showsWaveform {
                    WaveformView(waveform: clip.waveform, isReading: !clip.isWaveformRead,
                                 contentWidth: width, drawn: drawn, volume: controller.volumeEnvelope, duration: duration)
                        .frame(width: drawn.upperBound - drawn.lowerBound, height: waveformHeight)
                        .offset(x: drawn.lowerBound)
                }
            }

            if controller.hasMarks {
                // Dim everything outside the marked range.
                if let left = clamp(0, inX) {
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: left.width, height: height)
                        .offset(x: left.x)
                }
                if let right = clamp(outX, width) {
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: right.width, height: height)
                        .offset(x: right.x)
                }
                // Ends beyond the drawn part are pushed off screen, so their corners don't show.
                let borderStart = max(inX, drawn.lowerBound - 20)
                let borderEnd = min(max(outX, inX + borderWidth * 2), drawn.upperBound + 20)
                if borderEnd > borderStart {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.yellow, lineWidth: borderWidth)
                        .frame(width: borderEnd - borderStart, height: height)
                        .offset(x: borderStart)
                        .allowsHitTesting(false)
                }
                // A white handle fades in over the edge being pointed at or dragged.
                edgeHandle(.inPoint)
                    .offset(x: handleX(centeredOn: inX + borderWidth / 2, width: width), y: -2)
                edgeHandle(.outPoint)
                    .offset(x: handleX(centeredOn: outX - borderWidth / 2, width: width), y: -2)
            }

            // Playhead: thickens while pointed at or dragged.
            let playheadX = x(controller.currentTime)
            let lineWidth: CGFloat = isPlayheadActive(at: playheadX) ? 4 : 2
            RoundedRectangle(cornerRadius: lineWidth / 2)
                .fill(.white)
                .shadow(radius: 2)
                .frame(width: lineWidth, height: height + 8)
                // Faint while thin, so it doesn't hide the picture; full strength when grabbed.
                .opacity(lineWidth > 2 ? 1 : 0.25)
                .offset(x: min(max(0, playheadX - lineWidth / 2), width - lineWidth), y: -4)
                .animation(.easeOut(duration: 0.12), value: lineWidth)
                .allowsHitTesting(false)

            if showsWaveform, controller.isEditingVolume || !controller.volumeEnvelope.isEmpty {
                VolumeLine(controller: controller, isEditing: controller.isEditingVolume, clock: controller.clock,
                           duration: duration, contentWidth: width, drawn: drawn, height: waveformHeight)
                    .frame(width: drawn.upperBound - drawn.lowerBound, height: waveformHeight)
                    .offset(x: drawn.lowerBound, y: filmHeight + waveformGap)
            }

            if controller.hasMarks {
                edgeGrabArea(.inPoint)
                    .offset(x: min(max(0, inX - edgeGrabWidth / 2), width - edgeGrabWidth))
                    .gesture(drag(.inPoint, width: width, duration: duration))
                edgeGrabArea(.outPoint)
                    .offset(x: min(max(0, outX - edgeGrabWidth / 2), width - edgeGrabWidth))
                    .gesture(drag(.outPoint, width: width, duration: duration))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(drag(.playhead, width: width, duration: duration))
        // Double-clicking the waveform while editing the volume adds a keyframe there.
        .simultaneousGesture(
            SpatialTapGesture(count: 2, coordinateSpace: .named("scrubber")).onEnded { value in
                guard controller.isEditingVolume, showsWaveform, value.location.y > filmHeight else { return }
                let time = min(max(0, Double(value.location.x / width) * duration), duration)
                let clock = controller.clock
                let snapped = clock.fps > 0 ? clock.seconds(ofFrame: Int((time * clock.fps).rounded())) : time
                controller.selectedKeyframe = controller.volumeEnvelope.addKeyframe(
                    at: min(snapped, duration), minimumGap: clock.fps > 0 ? clock.seconds(ofFrame: 1) / 2 : 0.01)
            }
        )
        .onContinuousHover(coordinateSpace: .named("scrubber")) { phase in
            if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
        }
    }

    /// The part of `start...end` that's drawn, as a position and width.
    private func clamp(_ start: CGFloat, _ end: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        let low = max(start, drawn.lowerBound), high = min(end, drawn.upperBound)
        return high > low ? (low, high - low) : nil
    }

    private func isPlayheadActive(at playheadX: CGFloat) -> Bool {
        if anchor?.target == .playhead { return true }
        guard anchor == nil, let hoverX else { return false }
        return abs(hoverX - playheadX) <= playheadReach
    }

    private func isEdgeActive(_ edge: Target) -> Bool {
        anchor.map { $0.target == edge } ?? (hoveredEdge == edge)
    }

    /// Where a handle centered on `center` starts, kept inside the strip.
    private func handleX(centeredOn center: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, center - edgeHandleWidth / 2), max(0, width - edgeHandleWidth))
    }

    /// A white rounded grab handle over the in or out edge, shown while it's pointed at or dragged.
    private func edgeHandle(_ edge: Target) -> some View {
        RoundedRectangle(cornerRadius: edgeHandleWidth / 2)
            .fill(.white)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .frame(width: edgeHandleWidth, height: height + 4)
            .opacity(isEdgeActive(edge) ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isEdgeActive(edge))
            .allowsHitTesting(false)
    }

    /// An invisible strip over the in or out edge that can be dragged. Only over the filmstrip
    /// while editing the volume, so it doesn't cover keyframes.
    private func edgeGrabArea(_ edge: Target) -> some View {
        Color.clear
            .frame(width: edgeGrabWidth, height: controller.isEditingVolume ? filmHeight : height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredEdge = edge } else if hoveredEdge == edge { hoveredEdge = nil }
            }
            .help(edge == .inPoint ? "Drag to move the in point. Hold Shift for fine control, Shift-Command for extra fine." : "Drag to move the out point. Hold Shift for fine control, Shift-Command for extra fine.")
            .accessibilityLabel(edge == .inPoint ? "In point" : "Out point")
    }

    private func drag(_ target: Target, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: target == .playhead ? 0 : 1, coordinateSpace: .named("scrubber"))
            .onChanged { value in
                let x = value.location.x
                let speed = Self.dragSpeed(for: NSEvent.modifierFlags)

                if anchor == nil {
                    let start: Double = switch target {
                    case .playhead:
                        // A plain click jumps to the spot; a Shift-click, or grabbing the line itself,
                        // keeps the playhead where it is.
                        speed < 1 || abs(x - CGFloat(controller.currentTime / duration) * width) <= playheadReach
                            ? controller.currentTime : Double(min(max(0, x / width), 1)) * duration
                    case .inPoint: controller.markedRange.lowerBound
                    case .outPoint: controller.markedRange.upperBound
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
                    // Clicking the waveform away from the keyframes deselects them.
                    if controller.isEditingVolume, value.startLocation.y > filmHeight {
                        controller.selectedKeyframe = nil
                    }
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

    /// Pictures along the strip: one block per frame when frames are wide enough, otherwise
    /// thumbnails side by side.
    @ViewBuilder
    private var filmstrip: some View {
        let drawn = drawn
        let look = clip.enhanceSettings.colorLook
        if frameWidth >= Self.frameBlockWidth {
            let first = max(0, Int(drawn.lowerBound / frameWidth))
            let last = min(controller.frameCount - 1, Int(drawn.upperBound / frameWidth))
            ZStack(alignment: .topLeading) {
                if first <= last {
                    ForEach(first...last, id: \.self) { frame in
                        FrameBlock(image: frames.image(frame, look: look)
                                   ?? clip.thumbnail(near: controller.clock.seconds(ofFrame: frame)))
                            .frame(width: max(1, frameWidth - frameGap), height: filmHeight)
                            .offset(x: CGFloat(frame) * frameWidth + frameGap / 2)
                    }
                }
            }
            .frame(width: contentWidth, height: filmHeight, alignment: .topLeading)
        } else {
            // One rounded strip, cut to the drawn part (its cut ends are off screen).
            ZStack(alignment: .topLeading) {
                ForEach(tiles(in: drawn), id: \.index) { tile in
                    let time = Double((tile.x + tile.width / 2) / contentWidth) * duration
                    let frame = min(controller.frameCount - 1, max(0, Int((tile.x + tile.width / 2) / frameWidth)))
                    let image = (zoom > 1 ? frames.image(frame, look: look) : nil) ?? clip.thumbnail(near: time)
                    FrameBlock(image: image, cornerRadius: 0, outlined: false)
                        .frame(width: tile.width, height: filmHeight)
                        .offset(x: tile.x - drawn.lowerBound)
                }
            }
            .frame(width: drawn.upperBound - drawn.lowerBound, height: filmHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15))
            }
            .offset(x: drawn.lowerBound)
            .frame(width: contentWidth, height: filmHeight, alignment: .topLeading)
        }
    }

    /// Thumbnail slots about 64 points wide across the whole strip, limited to `range`.
    private func tiles(in range: ClosedRange<CGFloat>) -> [(index: Int, x: CGFloat, width: CGFloat)] {
        let count = max(1, Int(contentWidth / 64))
        let width = contentWidth / CGFloat(count)
        let first = max(0, Int(range.lowerBound / width))
        let last = min(count - 1, Int(range.upperBound / width))
        guard first <= last else { return [] }
        return (first...last).map { ($0, CGFloat($0) * width, width) }
    }
}

/// One frame's picture: a small rounded block, like a clip on the timeline but tighter.
private struct FrameBlock: View {
    let image: CGImage?
    var cornerRadius: CGFloat = 3
    var outlined = true

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.15))
            }
        }
    }
}

/// The clip's volume as a line over the waveform. While editing, its keyframes can be dragged
/// (up and down for the level, sideways to move them; Shift for fine control) and right-clicked
/// to switch between linear and spline or delete them. Clicking one selects it. Only the drawn part of the strip is drawn.
private struct VolumeLine: View {
    let controller: ClipPlayerController
    let isEditing: Bool
    let clock: FrameClock
    let duration: Double
    let contentWidth: CGFloat
    let drawn: ClosedRange<CGFloat>
    let height: CGFloat

    private struct DragStart {
        var id: UUID
        var time: Double
        var position: Double
        var translation: CGSize
        var speed: Double
    }

    @State private var dragStart: DragStart?
    @State private var hovered: UUID?

    /// Keyframes stay this far from the top and bottom, so they can be grabbed at the extremes.
    private let inset: CGFloat = 6
    private let keySize: CGFloat = 11

    private var usableHeight: CGFloat { max(1, height - inset * 2) }
    private func x(_ time: Double) -> CGFloat { CGFloat(time / duration) * contentWidth - drawn.lowerBound }
    private func y(_ position: Double) -> CGFloat { inset + (1 - CGFloat(position)) * usableHeight }

    var body: some View {
        let envelope = controller.volumeEnvelope
        let width = drawn.upperBound - drawn.lowerBound

        ZStack(alignment: .topLeading) {
            if isEditing {
                // 0 dB: the sound as recorded.
                Path { path in
                    let zero = y(VolumeEnvelope.position(forDB: 0))
                    path.move(to: CGPoint(x: 0, y: zero))
                    path.addLine(to: CGPoint(x: width, y: zero))
                }
                .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            line(envelope, width: width)
                .stroke(.white.opacity(isEditing ? 0.95 : 0.6), style: StrokeStyle(lineWidth: isEditing ? 1.5 : 1, lineJoin: .round))
                .shadow(color: .black.opacity(0.5), radius: 1)

            if isEditing {
                ForEach(visibleKeys(envelope, width: width)) { key in
                    handle(key)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(isEditing)
        .accessibilityHidden(!isEditing)
    }

    /// The line across the drawn part, a point every two points along.
    private func line(_ envelope: VolumeEnvelope, width: CGFloat) -> Path {
        Path { path in
            var started = false
            var column: CGFloat = 0
            while column <= width + 2 {
                let time = Double((drawn.lowerBound + column) / contentWidth) * duration
                let point = CGPoint(x: column, y: y(envelope.position(at: time)))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                column += 2
            }
        }
    }

    private func visibleKeys(_ envelope: VolumeEnvelope, width: CGFloat) -> [VolumeEnvelope.Keyframe] {
        envelope.keyframes.filter { (-keySize...(width + keySize)).contains(x($0.time)) }
    }

    private func handle(_ key: VolumeEnvelope.Keyframe) -> some View {
        let position = VolumeEnvelope.position(forDB: key.gainDB)
        let isActive = dragStart?.id == key.id || (dragStart == nil && hovered == key.id)
        let isSelected = controller.selectedKeyframe == key.id
        return ZStack {
            // Diamonds meet the line at a corner; circles ease through it.
            Group {
                // Selected: filled with the accent color and ringed in white.
                if key.isSmooth {
                    Circle().fill(isSelected ? Color.accentColor : .white)
                        .overlay(Circle().strokeBorder(isSelected ? .white : .black.opacity(0.5), lineWidth: isSelected ? 2 : 1))
                } else {
                    Rectangle().fill(isSelected ? Color.accentColor : .white)
                        .overlay(Rectangle().strokeBorder(isSelected ? .white : .black.opacity(0.5), lineWidth: isSelected ? 2 : 1))
                        .rotationEffect(.degrees(45))
                        .scaleEffect(0.78)
                }
            }
            .frame(width: keySize, height: keySize)
            .scaleEffect(isActive ? 1.25 : 1)
            .shadow(color: .black.opacity(0.4), radius: 1.5)
        }
        .frame(width: keySize + 8, height: keySize + 8)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if isActive {
                Text(VolumeEnvelope.label(forDB: key.gainDB))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: position > 0.8 ? keySize + 18 : -(keySize + 6))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.1), value: isActive)
        .onHover { inside in
            if inside { hovered = key.id } else if hovered == key.id { hovered = nil }
        }
        .gesture(drag(key))
        .contextMenu {
            Picker("Curve", selection: Binding(
                get: { controller.volumeEnvelope.keyframe(key.id)?.isSmooth ?? false },
                set: { controller.volumeEnvelope.setSmooth(key.id, $0) }
            )) {
                Text("Linear").tag(false)
                Text("Spline").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Delete Keyframe", role: .destructive) {
                controller.volumeEnvelope.remove(key.id)
                if hovered == key.id { hovered = nil }
                if controller.selectedKeyframe == key.id { controller.selectedKeyframe = nil }
            }
        }
        .help("\(VolumeEnvelope.label(forDB: key.gainDB)). Drag to change the volume or move the keyframe; hold Shift for fine control. Right-click to switch between linear and spline, or to delete it.")
        .accessibilityElement()
        .accessibilityLabel("Volume keyframe at \(clock.timecode(seconds: key.time))")
        .accessibilityValue(VolumeEnvelope.label(forDB: key.gainDB))
        .position(x: x(key.time), y: y(position))
    }

    private func drag(_ key: VolumeEnvelope.Keyframe) -> some Gesture {
        // In the strip's space, which doesn't move with the keyframe.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
            .onChanged { value in
                let speed = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                guard let current = controller.volumeEnvelope.keyframe(key.id) else { return }
                if dragStart?.id != key.id {
                    controller.selectedKeyframe = key.id
                    dragStart = DragStart(id: key.id, time: current.time, position: VolumeEnvelope.position(forDB: current.gainDB),
                                          translation: value.translation, speed: speed)
                } else if let start = dragStart, start.speed != speed {
                    // Shift pressed or let go mid-drag: carry on from here at the new speed.
                    dragStart = DragStart(id: key.id, time: current.time, position: VolumeEnvelope.position(forDB: current.gainDB),
                                          translation: value.translation, speed: speed)
                }
                guard let start = dragStart else { return }
                let dx = value.translation.width - start.translation.width
                let dy = value.translation.height - start.translation.height

                let frame = clock.fps > 0 ? clock.seconds(ofFrame: 1) : 0.01
                let range = controller.volumeEnvelope.movableRange(of: key.id, duration: duration, gap: frame)
                var time = start.time + Double(dx / contentWidth) * duration * start.speed
                if clock.fps > 0 { time = clock.seconds(ofFrame: Int((time * clock.fps).rounded())) }
                time = min(max(range.lowerBound, time), range.upperBound)

                let position = min(1, max(0, start.position - Double(dy / usableHeight) * start.speed))
                let db = VolumeEnvelope.db(forPosition: position)
                controller.volumeEnvelope.move(key.id, to: time, gainDB: db.isFinite ? db : VolumeEnvelope.minDB)
            }
            .onEnded { _ in dragStart = nil }
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
                // The full-screen player handles its own keys.
                guard let controller, let window = event.window, window == NSApp.mainWindow,
                      window.identifier != FullScreenPlayer.windowID,
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
