import SwiftUI

/// The horizontal strip of clips. Drop files or media rows to add; drag clips to reorder.
struct TimelineEditorView: View {
    @Environment(ProjectStore.self) private var store
    @State private var pointsPerSecond: Double = 30
    @State private var visibleWidth: CGFloat = 0
    @State private var isTargeted = false
    @FocusState private var isFocused: Bool

    private let spacing: CGFloat = 4
    private let padding: CGFloat = 12
    private let minimumClipWidth: CGFloat = 48

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
                                range: store.trimRange(of: item),
                                isSelected: item.id == store.selectedTimelineItemID
                            )
                            .frame(width: width(of: item))
                            .onTapGesture {
                                store.selectedTimelineItemID = item.id
                                isFocused = true
                            }
                            .draggable(item.dragURL) {
                                ClipThumbnail(clip: clip, time: store.trimRange(of: item).lowerBound)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .contextMenu { itemMenu(for: item) }
                        }
                    }
                }
                .padding(padding)
                .frame(minWidth: visibleWidth, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.selectedTimelineItemID = nil }
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
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $pointsPerSecond, in: 5...200)
                .frame(width: 120)
                .help("Zoom the timeline")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func itemMenu(for item: TimelineItem) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateTimelineItem(item.id) }
        Button("Reset Trim", systemImage: "arrow.uturn.backward") { store.resetTrim(for: item.id) }
        Divider()
        Button("Remove from Timeline", systemImage: "trash", role: .destructive) {
            store.removeTimelineItem(item.id)
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
                    Text(clip.name).lineLimit(1)
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
        .help(clip.name)
    }
}
