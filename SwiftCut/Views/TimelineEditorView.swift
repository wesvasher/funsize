import SwiftUI

/// The horizontal strip of clips. Drop files or media rows to add; drag clips to reorder.
struct TimelineEditorView: View {
    @Environment(ProjectStore.self) private var store
    let playback: TimelinePlayback
    @State private var pointsPerSecond: Double = 30
    @State private var visibleWidth: CGFloat = 0
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
            Spacer()
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
                Button { pointsPerSecond = fitPointsPerSecond } label: {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .help("Zoom out to fit the whole timeline")
                .disabled(store.timeline.isEmpty)
                .padding(.leading, 4)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 8)
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
    private var playhead: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.white)
                .shadow(radius: 2)
                .frame(width: 3, height: proxy.size.height - padding / 2)
                .offset(x: layout.x(at: playback.time) - 1.5, y: padding / 4)
        }
        .allowsHitTesting(false)
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
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int(proxy.size.width / 80))
            let length = range.upperBound - range.lowerBound

            ZStack(alignment: .bottomLeading) {
                if clip.hasVideo {
                    HStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { index in
                            ClipThumbnail(clip: clip, time: range.lowerBound + length * (Double(index) + 0.5) / Double(count))
                                .frame(width: proxy.size.width / CGFloat(count))
                        }
                    }
                } else {
                    Rectangle().fill(Color.green.opacity(0.35))
                    Image(systemName: "waveform")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .help((isSubclip ? "\(name) (subclip of \(clip.name))" : "\(clip.name) (whole source video)") + ". Double-click to open it in the viewer.")
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
