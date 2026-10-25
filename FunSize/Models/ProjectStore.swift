import AVFoundation
import Observation

/// Everything in the current session: imported media, the timeline, and selection.
@Observable
final class ProjectStore {
    let exporter: ExportManager

    var clips: [Clip] = []
    var timeline: [TimelineItem] = []
    var selection: Set<SidebarItem> = []
    var selectedTimelineItemID: UUID?
    var isImporting = false

    init(exporter: ExportManager) {
        self.exporter = exporter
    }

    // MARK: Lookup

    func clip(for id: UUID) -> Clip? {
        clips.first { $0.id == id }
    }

    var selectedClips: [Clip] {
        clips.filter { selection.contains(.clip($0.id)) }
    }

    var isTimelineSelected: Bool { selection == [.timeline] }

    var selectedTimelineItem: TimelineItem? {
        timeline.first { $0.id == selectedTimelineItemID }
    }

    func trimRange(of item: TimelineItem) -> ClosedRange<Double> {
        let duration = clip(for: item.clipID)?.duration ?? 0
        let end = min(item.trimEnd ?? duration, duration)
        return min(item.trimStart, end)...end
    }

    func duration(of item: TimelineItem) -> Double {
        let range = trimRange(of: item)
        return range.upperBound - range.lowerBound
    }

    var timelineDuration: Double {
        timeline.map(duration(of:)).reduce(0, +)
    }

    /// Changes whenever the combined video needs rebuilding.
    var timelineSignature: [String] {
        timeline.map { item in
            let range = trimRange(of: item)
            return "\(item.id)|\(range.lowerBound)|\(range.upperBound)"
        }
    }

    // MARK: Importing

    /// Adds supported files to the media list. Returns the clips (new or existing) for those files.
    @discardableResult
    func importFiles(_ urls: [URL], securityScoped: Bool = false) -> [Clip] {
        var result: [Clip] = []
        for url in urls {
            if securityScoped { _ = url.startAccessingSecurityScopedResource() }
            guard MediaLoader.isSupported(url) else { continue }
            if let existing = clips.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                result.append(existing)
                continue
            }
            let clip = Clip(url: url)
            clips.append(clip)
            result.append(clip)
            Task { await MediaLoader.load(clip) }
        }
        return result
    }

    /// Imports files and selects them, so Export works right away.
    func importAndSelect(_ urls: [URL], securityScoped: Bool = false) {
        let imported = importFiles(urls, securityScoped: securityScoped)
        guard !imported.isEmpty else { return }
        selection = Set(imported.map { .clip($0.id) })
    }

    func removeClips(_ ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }
        timeline.removeAll { ids.contains($0.clipID) }
        selection = selection.filter {
            if case .clip(let id) = $0 { return !ids.contains(id) }
            return true
        }
    }

    // MARK: Timeline editing

    func addToTimeline(_ clips: [Clip], at index: Int? = nil) {
        let items = clips.map { TimelineItem(clipID: $0.id, trimStart: $0.inPoint ?? 0, trimEnd: $0.outPoint) }
        let insertAt = min(index ?? timeline.count, timeline.count)
        timeline.insert(contentsOf: items, at: insertAt)
        selectedTimelineItemID = items.last?.id
    }

    func moveTimelineItem(_ id: UUID, to index: Int) {
        guard let from = timeline.firstIndex(where: { $0.id == id }) else { return }
        var destination = index
        if from < destination { destination -= 1 }
        let item = timeline.remove(at: from)
        timeline.insert(item, at: min(max(destination, 0), timeline.count))
    }

    func duplicateTimelineItem(_ id: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return }
        let original = timeline[index]
        let copy = TimelineItem(clipID: original.clipID, trimStart: original.trimStart, trimEnd: original.trimEnd)
        timeline.insert(copy, at: index + 1)
        selectedTimelineItemID = copy.id
    }

    func removeTimelineItem(_ id: UUID) {
        timeline.removeAll { $0.id == id }
        if selectedTimelineItemID == id { selectedTimelineItemID = nil }
    }

    /// Minimum length a trimmed clip can have.
    static let minimumClipLength = 0.1

    func setTrimStart(_ value: Double, for id: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return }
        let end = trimRange(of: timeline[index]).upperBound
        timeline[index].trimStart = min(max(0, value), end - Self.minimumClipLength)
    }

    func setTrimEnd(_ value: Double, for id: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == id }),
              let clip = clip(for: timeline[index].clipID) else { return }
        let start = timeline[index].trimStart
        timeline[index].trimEnd = max(min(value, clip.duration), start + Self.minimumClipLength)
    }

    func resetTrim(for id: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return }
        timeline[index].trimStart = 0
        timeline[index].trimEnd = nil
    }

    /// Handles anything dropped on the timeline: new files, media-list rows, or reordered items.
    func handleTimelineDrop(_ urls: [URL], at index: Int) -> Bool {
        if let url = urls.first, let itemID = TimelineItem.id(fromDragURL: url) {
            moveTimelineItem(itemID, to: index)
            return true
        }
        let clips = importFiles(urls)
        guard !clips.isEmpty else { return false }
        addToTimeline(clips, at: index)
        return true
    }

    // MARK: Building and exporting

    var timelineSegments: [CompositionBuilder.Segment] {
        timeline.compactMap { item in
            guard let clip = clip(for: item.clipID), clip.isLoaded else { return nil }
            let range = trimRange(of: item)
            return .init(url: clip.url, start: range.lowerBound, end: range.upperBound)
        }
    }

    func buildTimeline() async throws -> CompositionBuilder.Result {
        try await CompositionBuilder.build(timelineSegments)
    }

    var canExport: Bool {
        isTimelineSelected ? !timeline.isEmpty : !selectedClips.isEmpty
    }

    /// Exports whatever is selected: the timeline, or each selected clip.
    func exportSelection(as format: ExportFormat) {
        if isTimelineSelected {
            exportTimeline(as: format)
        } else {
            for clip in selectedClips {
                exportClip(clip, as: format)
            }
        }
    }

    /// Exports a clip, or just its in/out range when one is marked.
    func exportClip(_ clip: Clip, as format: ExportFormat) {
        var timeRange: CMTimeRange?
        if clip.hasMarks {
            let range = clip.markedRange
            timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 90_000),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 90_000)
            )
        }
        exporter.export(asset: AVURLAsset(url: clip.url), timeRange: timeRange, name: clip.name, format: format)
    }

    func exportTimeline(as format: ExportFormat) {
        Task {
            do {
                let result = try await buildTimeline()
                exporter.export(
                    asset: result.composition,
                    videoComposition: result.videoComposition,
                    name: "Timeline \(Date.now.formatted(.dateTime.year().month().day().hour().minute()))"
                        .replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "."),
                    format: format
                )
            } catch {
                exporter.jobs.insert(failedJob(error, format: format), at: 0)
                exporter.isShowingActivity = true
            }
        }
    }

    private func failedJob(_ error: Error, format: ExportFormat) -> ExportJob {
        let job = ExportJob(name: "Timeline", format: format, outputURL: exporter.destinationFolder)
        job.state = .failed(error.localizedDescription)
        return job
    }
}
