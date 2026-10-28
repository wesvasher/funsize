import SwiftUI

/// The horizontal strip of clips. Drop files or media rows to add; drag clips to reorder.
struct TimelineEditorView: View {
    @Environment(ProjectStore.self) private var store
    let playback: TimelinePlayback
    @State private var pointsPerSecond: Double = 30
    @State private var visibleWidth: CGFloat = 0
    /// How far the strip is scrolled, and its full width, for the navigator.
    @State private var scrollX: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isTargeted = false
    @FocusState private var isFocused: Bool

    private let spacing: CGFloat = 4
    private let padding: CGFloat = 12
    private let minimumClipWidth: CGFloat = 48
    /// Height of the strip above the clips that moves the playhead.
    private let scrubHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    ForEach(store.timeline) { item in
                        if let clip = store.clip(for: item.clipID) {
                            TimelineClipView(
                                clip: clip,
                                name: store.name(of: item),
                                isSubclip: item.subclipID != nil,
                                range: store.trimRange(of: item),
                                volume: store.volume(of: item),
                                isSelected: item.id == store.selectedTimelineItemID
                            )
                            .frame(width: width(of: item))
                            .onTapGesture {
                                store.selectedTimelineItemID = item.id
                                isFocused = true
                            }
                            // Alongside the single click, so selecting doesn't wait to rule out a double-click.
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                            .draggable(item.dragURL) {
                                ClipThumbnail(clip: clip, time: store.trimRange(of: item).lowerBound)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .contextMenu { itemMenu(for: item) }
                        }
                    }
                }
                .padding(.horizontal, padding)
                .padding(.bottom, padding)
                .padding(.top, scrubHeight)
                .frame(minWidth: visibleWidth, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.selectedTimelineItemID = nil }
                .overlay(alignment: .top) {
                    if !store.timeline.isEmpty {
                        scrubArea
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !store.timeline.isEmpty {
                        playhead
                    }
                }
                .coordinateSpace(.named("timelineStrip"))
                .dropDestination(for: URL.self) { urls, location in
                    store.handleTimelineDrop(urls, at: insertionIndex(at: location.x))
                } isTargeted: { isTargeted = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.contentSize.width] } action: { _, new in
                scrollX = new[0]
                contentWidth = new[1]
            }
            .overlay {
                if store.timeline.isEmpty {
                    Text("Drag clips here to combine them")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onDeleteCommand {
                if let id = store.selectedTimelineItemID { store.removeTimelineItem(id) }
            }
        }
        .background(.background.secondary)
    }

    private var header: some View {
        HStack {
            Text("Timeline")
                .font(.headline)
            Text("\(store.timeline.count) clips · \(store.timelineDuration.timecode)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if isZoomedIn {
                navigator
                    .frame(minWidth: 80, maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            } else {
                Spacer()
            }
            OutputLevelMeter(audio: store.timelineAudio)
                .padding(.trailing, 8)
            HStack(spacing: 4) {
                Button { zoom(by: 1 / zoomStep) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                .disabled(pointsPerSecond <= zoomRange.lowerBound)
                Slider(value: $pointsPerSecond, in: zoomRange)
                    .frame(width: 120)
                    .help("Zoom the timeline")
                Button { zoom(by: zoomStep) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
                .disabled(pointsPerSecond >= zoomRange.upperBound)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: isZoomedIn)
    }

    /// Whether the clips run past the visible width (so the strip scrolls).
    private var isZoomedIn: Bool {
        !store.timeline.isEmpty && visibleWidth > 0 && contentWidth > visibleWidth + 1
    }

    /// The whole timeline in miniature, with the part in view outlined.
    private var navigator: some View {
        let layout = layout
        let items = store.timeline
        return StripNavigator(
            contentWidth: contentWidth,
            visible: scrollX...(scrollX + visibleWidth),
            playheadX: layout.x(at: playback.time),
            scroll: { left in
                scrollX = left
                scrollPosition.scrollTo(x: left)
            },
            close: { pointsPerSecond = fitPointsPerSecond }
        ) { width in
            let scale = width / max(1, contentWidth)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.quaternary.opacity(0.5))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if let clip = store.clip(for: item.clipID) {
                        let start = layout.start + layout.widths[..<index].reduce(0, +) + layout.spacing * CGFloat(index)
                        ClipThumbnail(clip: clip, time: store.trimRange(of: item).lowerBound)
                            .frame(width: max(1, layout.widths[index] * scale - 1))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .offset(x: start * scale)
                    }
                }
            }
        }
    }

    // MARK: Zoom

    /// How much each click of the zoom buttons changes the zoom.
    private let zoomStep = 1.5

    /// The slider's range. It reaches down far enough to fit a long timeline.
    private var zoomRange: ClosedRange<Double> {
        min(5, fitPointsPerSecond)...200
    }

    private func zoom(by factor: Double) {
        let range = zoomRange
        pointsPerSecond = min(range.upperBound, max(range.lowerBound, pointsPerSecond * factor))
    }

    /// The zoom that shows every clip in the visible width.
    private var fitPointsPerSecond: Double {
        let durations = store.timeline.map(store.duration(of:))
        guard !durations.isEmpty, visibleWidth > 0 else { return 5 }
        let available = Double(visibleWidth - 2 * padding - spacing * CGFloat(durations.count - 1))
        func totalWidth(_ pps: Double) -> Double {
            durations.reduce(0) { $0 + max(Double(minimumClipWidth), $1 * pps) }
        }
        // Clips have a minimum width, so search for the largest zoom that still fits.
        var low = 0.01, high = 200.0
        guard totalWidth(high) > available else { return high }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if totalWidth(mid) <= available { low = mid } else { high = mid }
        }
        return low
    }

    @ViewBuilder
    private func itemMenu(for item: TimelineItem) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateTimelineItem(item.id) }
        if item.subclipID != nil {
            Button("Use Whole Source Video", systemImage: "arrow.uturn.backward") { store.resetTrim(for: item.id) }
            Button("Show Subclip", systemImage: "scissors") { open(item) }
        } else {
            Button("Show Source Video", systemImage: "film") { open(item) }
        }
        Divider()
        Button("Remove from Timeline", systemImage: "trash", role: .destructive) {
            store.removeTimelineItem(item.id)
        }
    }

    /// Where each clip sits, for placing the playhead.
    private var layout: TimelineLayout {
        TimelineLayout(durations: store.timeline.map(store.duration(of:)),
                       widths: store.timeline.map(width(of:)), spacing: spacing, start: padding)
    }

    /// The strip above the clips: click or drag in it to move the playhead.
    /// (Clicking a clip only selects it.)
    private var scrubArea: some View {
        let layout = layout
        return Rectangle()
            .fill(.clear)
            .frame(height: scrubHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineStrip"))
                    .onChanged { value in playback.scrub(to: layout.time(at: value.location.x)) }
            )
            .help("Click or drag here to move the playhead")
            .accessibilityElement()
            .accessibilityLabel("Playhead")
            .accessibilityValue(playback.time.timecode)
            .accessibilityAdjustableAction { direction in
                let step = 1.0 / 30
                playback.scrub(to: min(max(0, playback.time + (direction == .increment ? step : -step)), store.timelineDuration))
            }
    }

    /// A tall white line across the clips at the current time, like the clip viewer's scrubber.
    /// It can be grabbed and dragged: the grab area is a few points either side of the line,
    /// so clicks farther away still select the clip underneath.
    private var playhead: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !playback.isPlaying)) { _ in
                ZStack {
                    Color.clear
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .shadow(radius: 2)
                        .frame(width: playheadIsActive ? 4 : 2)
                        // Faint while thin, so it doesn't hide the picture; full strength when grabbed.
                        .opacity(playheadIsActive ? 1 : 0.25)
                }
                .animation(.easeOut(duration: 0.12), value: playheadIsActive)
                .frame(width: playheadGrabWidth, height: proxy.size.height - padding / 2)
                .contentShape(Rectangle())
                .offset(x: playheadX - playheadGrabWidth / 2, y: padding / 4)
                .gesture(playheadDrag)
                .onHover { playheadIsHovered = $0 }
                .help("Drag to move the playhead")
            }
        }
    }

    /// Where the playhead line sits. While playing it glides through the gaps between clips;
    /// otherwise it sits exactly on the frame shown.
    private var playheadX: CGFloat {
        playback.isPlaying ? layout.continuousX(at: playback.liveTime) : layout.x(at: playback.time)
    }

    /// How wide the playhead's grab area is.
    private let playheadGrabWidth: CGFloat = 12
    /// Where the playhead was when a drag began, so grabbing it slightly off the line doesn't make it jump.
    @State private var playheadDragStart: CGFloat?
    @State private var playheadIsHovered = false
    /// The line thickens while the pointer is over it, and stays thick while it's being dragged.
    private var playheadIsActive: Bool { playheadIsHovered || playheadDragStart != nil }

    private var playheadDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineStrip"))
            .onChanged { value in
                let layout = layout
                let start = playheadDragStart ?? layout.x(at: playback.time)
                playheadDragStart = start
                playback.scrub(to: layout.time(at: start + value.translation.width))
            }
            .onEnded { _ in playheadDragStart = nil }
    }

    /// Shows the item's subclip (or its whole source video) in the clip viewer.
    private func open(_ item: TimelineItem) {
        if let id = item.subclipID {
            store.selection = [.subclip(id)]
        } else {
            store.selection = [.clip(item.clipID)]
        }
    }

    private func width(of item: TimelineItem) -> CGFloat {
        max(minimumClipWidth, store.duration(of: item) * pointsPerSecond)
    }

    /// Which gap a drop at `x` lands in.
    private func insertionIndex(at x: CGFloat) -> Int {
        var cursor = padding
        for (index, item) in store.timeline.enumerated() {
            let w = width(of: item)
            if x < cursor + w / 2 { return index }
            cursor += w + spacing
        }
        return store.timeline.count
    }
}

private struct TimelineClipView: View {
    let clip: Clip
    let name: String
    let isSubclip: Bool
    let range: ClosedRange<Double>
    /// The volume keyframes it plays with (its subclip's own, or the source video's).
    let volume: VolumeEnvelope
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int(proxy.size.width / 80))
            let length = range.upperBound - range.lowerBound

            ZStack(alignment: .topLeading) {
                VStack(spacing: 1) {
                    if clip.hasVideo {
                        HStack(spacing: 0) {
                            ForEach(0..<count, id: \.self) { index in
                                ClipThumbnail(clip: clip, time: range.lowerBound + length * (Double(index) + 0.5) / Double(count))
                                    .frame(width: proxy.size.width / CGFloat(count))
                            }
                        }
                    }
                    if clip.hasAudio || !clip.hasVideo {
                        // Under the pictures, or the whole clip when it's only sound.
                        waveform(width: proxy.size.width)
                            .frame(height: clip.hasVideo ? min(40, max(16, proxy.size.height * 0.3)) : nil)
                    }
                }

                HStack(spacing: 4) {
                    if isSubclip {
                        Image(systemName: "scissors").foregroundStyle(.secondary)
                    }
                    Text(name).lineLimit(1)
                    Text(length.timecode).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 3 : 1)
        }
        .contentShape(Rectangle())
        .task(id: "\(clip.id) \(clip.isLoaded)") { await clip.readWaveform() }
        .help((isSubclip ? "\(name) (subclip of \(clip.name))" : "\(clip.name) (whole source video)") + ". Double-click to open it in the viewer.")
    }

    /// The part of the clip's sound this item plays, after its volume keyframes.
    private func waveform(width: CGFloat) -> some View {
        let duration = max(clip.duration, 0.001)
        let length = max(range.upperBound - range.lowerBound, 0.001)
        // The whole file at this item's scale, with only the item's part drawn.
        let fullWidth = max(1, width * duration / length)
        let start = CGFloat(range.lowerBound / duration) * fullWidth
        return WaveformView(waveform: clip.waveform, isReading: clip.hasAudio && !clip.isWaveformRead,
                            contentWidth: fullWidth, drawn: start...(start + max(1, width)),
                            volume: volume, duration: duration, cornerRadius: 0)
    }
}

/// Converts between time on the timeline and position along the strip of clips.
/// Clips are drawn side by side (each at least a minimum width), with gaps between.
nonisolated struct TimelineLayout {
    /// Each clip's length in seconds, in order.
    var durations: [Double]
    /// Each clip's drawn width.
    var widths: [CGFloat]
    var spacing: CGFloat
    /// Where the first clip starts.
    var start: CGFloat

    /// Position of `seconds` along the strip.
    func x(at seconds: Double) -> CGFloat {
        var cursor = start
        var clipStart = 0.0
        for (index, duration) in durations.enumerated() {
            let isLast = index == durations.count - 1
            if seconds < clipStart + duration || isLast {
                let fraction = duration > 0 ? min(max((seconds - clipStart) / duration, 0), 1) : 0
                return cursor + CGFloat(fraction) * widths[index]
            }
            cursor += widths[index] + spacing
            clipStart += duration
        }
        return start
    }

    /// Like `x(at:)`, but each clip's span includes the gap after it, so the playhead glides
    /// through the gaps during playback instead of hopping across them.
    func continuousX(at seconds: Double) -> CGFloat {
        var cursor = start
        var clipStart = 0.0
        for (index, duration) in durations.enumerated() {
            let isLast = index == durations.count - 1
            let span = widths[index] + (isLast ? 0 : spacing)
            if seconds < clipStart + duration || isLast {
                let fraction = duration > 0 ? min(max((seconds - clipStart) / duration, 0), 1) : 0
                return cursor + CGFloat(fraction) * span
            }
            cursor += widths[index] + spacing
            clipStart += duration
        }
        return start
    }

    /// The time at position `x` (in a gap between clips: the start of the next clip).
    func time(at x: CGFloat) -> Double {
        var cursor = start
        var clipStart = 0.0
        for (index, duration) in durations.enumerated() {
            let width = widths[index]
            if x < cursor + width || index == durations.count - 1 {
                let fraction = width > 0 ? min(max((x - cursor) / width, 0), 1) : 0
                return clipStart + Double(fraction) * duration
            }
            cursor += width + spacing
            clipStart += duration
        }
        return 0
    }
}
