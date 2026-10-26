import AppKit
import AVFoundation
import Observation

/// Everything in the current session: source videos, subclips, the timeline, and selection.
@Observable
final class ProjectStore {
    let exporter: ExportManager

    /// Source videos, in sidebar order.
    var clips: [Clip] = []
    /// Parts of source videos. Shown under their source in the sidebar.
    var subclips: [Subclip] = []
    var timeline: [TimelineItem] = []
    /// The timeline's frame size, frame rate, and fit (timeline inspector's Timeline Settings section).
    var timelineSettings = TimelineSettings()
    var selection: Set<SidebarItem> = []
    var selectedTimelineItemID: UUID?
    var isImporting = false
    /// How loud each timeline item's part of its file is, by `loudnessKey`.
    private(set) var loudness: [String: LoudnessState] = [:]
    /// The timeline player's volume changes and live level.
    let timelineAudio = TimelineAudio()

    enum LoudnessState: Equatable {
        case measuring
        /// `nil` when the part has no sound.
        case measured(Loudness.Measurement?)
        case failed
    }

    init(exporter: ExportManager) {
        self.exporter = exporter
    }

    // MARK: Lookup

    func clip(for id: UUID) -> Clip? {
        clips.first { $0.id == id }
    }

    func subclip(for id: UUID) -> Subclip? {
        subclips.first { $0.id == id }
    }

    /// A source video's subclips, in the order they were made.
    func subclips(of clipID: UUID) -> [Subclip] {
        subclips.filter { $0.sourceID == clipID }
    }

    /// Selected source videos.
    var selectedClips: [Clip] {
        clips.filter { selection.contains(.clip($0.id)) }
    }

    var selectedSubclips: [Subclip] {
        subclips.filter { selection.contains(.subclip($0.id)) }
    }

    /// Selected source videos and subclips, in sidebar order.
    var selectedMedia: [SidebarItem] {
        clips.flatMap { clip in
            [SidebarItem.clip(clip.id)] + subclips(of: clip.id).map { .subclip($0.id) }
        }
        .filter(selection.contains)
    }

    /// When one source video or subclip is selected: the source, and the subclip if it's one.
    var singleSelectedMedia: (clip: Clip, subclip: Subclip?)? {
        guard selection.count == 1, let item = selection.first else { return nil }
        switch item {
        case .clip(let id):
            return clip(for: id).map { ($0, nil) }
        case .subclip(let id):
            guard let subclip = subclip(for: id), let clip = clip(for: subclip.sourceID) else { return nil }
            return (clip, subclip)
        case .timeline:
            return nil
        }
    }

    var isTimelineSelected: Bool { selection == [.timeline] }

    var selectedTimelineItem: TimelineItem? {
        timeline.first { $0.id == selectedTimelineItemID }
    }

    /// The part of the source video a timeline item plays.
    func trimRange(of item: TimelineItem) -> ClosedRange<Double> {
        let duration = clip(for: item.clipID)?.duration ?? 0
        if let id = item.subclipID, let subclip = subclip(for: id) {
            return subclip.range(in: duration)
        }
        return 0...duration
    }

    /// The subclip's name, or the source video's for a whole source.
    func name(of item: TimelineItem) -> String {
        if let id = item.subclipID, let subclip = subclip(for: id) { return subclip.name }
        return clip(for: item.clipID)?.name ?? ""
    }

    func range(of subclip: Subclip) -> ClosedRange<Double> {
        subclip.range(in: clip(for: subclip.sourceID)?.duration ?? 0)
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
            // The clip's effects and color too, so the timeline shows changes made in the clip viewer.
            let effects = clip(for: item.clipID)?.enhanceSettings.hashValue ?? 0
            return "\(item.id)|\(range.lowerBound)|\(range.upperBound)|\(effects)"
        } + ["\(timelineSettings.pictureOnly)"]
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
            clip.bookmark = Clip.makeBookmark(for: url)
            clips.append(clip)
            result.append(clip)
            Task {
                await MediaLoader.load(clip)
                // New Apple Log clips get the conversion chosen in Settings › Color.
                if clip.lutID == nil, let auto = clip.defaultLUTID {
                    clip.lutID = auto
                }
            }
        }
        return result
    }

    /// Imports files and selects them, so Export works right away.
    func importAndSelect(_ urls: [URL], securityScoped: Bool = false) {
        let imported = importFiles(urls, securityScoped: securityScoped)
        guard !imported.isEmpty else { return }
        selection = Set(imported.map { .clip($0.id) })
    }

    /// Removes source videos, with their subclips and timeline items. The files aren't touched.
    func removeClips(_ ids: Set<UUID>) {
        let subclipIDs = Set(subclips.filter { ids.contains($0.sourceID) }.map(\.id))
        clips.removeAll { ids.contains($0.id) }
        subclips.removeAll { subclipIDs.contains($0.id) }
        timeline.removeAll { ids.contains($0.clipID) }
        pruneSelection()
    }

    /// Removes subclips, and the timeline items that use them.
    func removeSubclips(_ ids: Set<UUID>) {
        subclips.removeAll { ids.contains($0.id) }
        timeline.removeAll { $0.subclipID.map(ids.contains) ?? false }
        pruneSelection()
    }

    /// Removes whatever is selected in the sidebar's media list.
    func removeSelectedMedia() {
        let selected = selectedMedia
        removeSubclips(Set(selected.compactMap { if case .subclip(let id) = $0 { id } else { nil } }))
        removeClips(Set(selected.compactMap { if case .clip(let id) = $0 { id } else { nil } }))
    }

    private func pruneSelection() {
        let clipIDs = Set(clips.map(\.id)), subclipIDs = Set(subclips.map(\.id))
        let kept = selection.filter {
            switch $0 {
            case .clip(let id): clipIDs.contains(id)
            case .subclip(let id): subclipIDs.contains(id)
            case .timeline: true
            }
        }
        if kept != selection { selection = kept }
        if let selected = selectedTimelineItemID, !timeline.contains(where: { $0.id == selected }) {
            selectedTimelineItemID = nil
        }
    }

    // MARK: Videos that can't be opened

    /// Source videos that couldn't be opened: moved, deleted, or the app has no permission
    /// (projects saved by FunSize, the app's old name, can't pass their permission on).
    var missingClips: [Clip] { clips.filter { $0.loadError != nil } }

    /// Points missing source videos at files the user chose, matching by file name.
    /// With one file chosen for one clip (`preferring`), uses it even if the name differs.
    /// Returns how many were relinked.
    @discardableResult
    func relink(_ urls: [URL], preferring chosen: Clip? = nil) -> Int {
        if let chosen, urls.count == 1, let url = urls.first {
            replaceSource(chosen, with: url)
            return 1
        }
        var count = 0
        for clip in missingClips {
            let name = clip.url.lastPathComponent
            if let url = urls.first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                replaceSource(clip, with: url)
                count += 1
            }
        }
        return count
    }

    /// Swaps in a new file for a source video, keeping its id, marks, and settings.
    private func replaceSource(_ old: Clip, with url: URL) {
        guard let index = clips.firstIndex(where: { $0 === old }) else { return }
        _ = url.startAccessingSecurityScopedResource()
        let clip = Clip(url: url, id: old.id)
        clip.bookmark = Clip.makeBookmark(for: url)
        clip.apply(old.record)
        clips[index] = clip
        Task { await MediaLoader.load(clip) }
    }

    // MARK: Subclips

    /// Makes a subclip from a source video's marked range, adds it to the end of the
    /// timeline, and clears the marks so the next range can be marked.
    @discardableResult
    func addSubclip(from clip: Clip) -> Subclip? {
        guard clip.hasMarks else { return nil }
        let range = clip.markedRange
        let subclip = makeSubclip(of: clip, start: range.lowerBound, end: clip.outPoint.map { _ in range.upperBound })
        clip.inPoint = nil
        clip.outPoint = nil
        addToTimeline([.subclip(subclip.id)])
        return subclip
    }

    private func makeSubclip(of clip: Clip, start: Double, end: Double?, after: Subclip? = nil) -> Subclip {
        let subclip = Subclip(sourceID: clip.id, name: nextSubclipName(for: clip), start: start, end: end)
        if let after, let index = subclips.firstIndex(where: { $0.id == after.id }) {
            subclips.insert(subclip, at: index + 1)
        } else {
            subclips.append(subclip)
        }
        return subclip
    }

    /// "IMG_0021 Subclip 3": the next number not already used for this source video.
    func nextSubclipName(for clip: Clip) -> String {
        let names = Set(subclips.map(\.name))
        var number = subclips(of: clip.id).count + 1
        while names.contains("\(clip.name) Subclip \(number)") { number += 1 }
        return "\(clip.name) Subclip \(number)"
    }

    // MARK: Saving and opening

    /// Everything a project file stores, built from the current state.
    var projectFile: ProjectFile {
        var file = ProjectFile(
            clips: clips.map(\.record),
            subclips: subclips.map(\.record),
            timeline: timeline.map { .init(id: $0.id, clipID: $0.clipID, subclipID: $0.subclipID,
                                           audio: $0.audio.isDefault ? nil : $0.audio) }
        )
        file.timelineSettings = timelineSettings
        return file
    }

    /// Brings the store in line with a project file: when opening it, and after Undo/Redo.
    /// Clips already open keep their loaded pictures and details.
    func apply(_ file: ProjectFile) {
        guard file != projectFile else { return }
        let existing = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = file.clips.map { record in
            let clip = existing[record.id] ?? Self.openClip(record)
            clip.apply(record)
            return clip
        }
        if updated.map(\.id) != clips.map(\.id) { clips = updated }

        let existingSubclips = Dictionary(subclips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updatedSubclips = file.subclips.map { record in
            let subclip = existingSubclips[record.id]
                ?? Subclip(id: record.id, sourceID: record.sourceID, name: record.name, start: record.start, end: record.end)
            subclip.apply(record)
            return subclip
        }
        if updatedSubclips.map(\.id) != subclips.map(\.id) { subclips = updatedSubclips }

        let items = file.timeline.map {
            TimelineItem(id: $0.id, clipID: $0.clipID, subclipID: $0.subclipID, audio: $0.audio ?? ItemAudio())
        }
        if items != timeline { timeline = items }
        if file.timelineSettings != timelineSettings { timelineSettings = file.timelineSettings }

        pruneSelection()
    }

    /// Selects something sensible after opening a project.
    func selectInitialItem() {
        guard selection.isEmpty else { return }
        if !timeline.isEmpty {
            selection = [.timeline]
        } else if let first = clips.first {
            selection = [.clip(first.id)]
        }
    }

    /// Finds a saved clip's video (following it if it moved) and starts loading it.
    private static func openClip(_ record: ProjectFile.ClipRecord) -> Clip {
        var url = URL(filePath: record.path)
        var bookmark = record.bookmark
        if let data = record.bookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = resolved.startAccessingSecurityScopedResource()
                url = resolved
                if isStale { bookmark = Clip.makeBookmark(for: resolved) ?? data }
            }
        }
        let clip = Clip(url: url, id: record.id)
        clip.bookmark = bookmark
        Task { await MediaLoader.load(clip) }
        return clip
    }

    // MARK: Timeline editing

    /// Adds whole source videos.
    func addToTimeline(_ clips: [Clip], at index: Int? = nil) {
        addToTimeline(clips.map { .clip($0.id) }, at: index)
    }

    /// Adds source videos (whole) and subclips, in the given order.
    func addToTimeline(_ media: [SidebarItem], at index: Int? = nil) {
        let items: [TimelineItem] = media.compactMap { entry in
            switch entry {
            case .clip(let id):
                return clip(for: id).map { TimelineItem(clipID: $0.id) }
            case .subclip(let id):
                return subclip(for: id).map { TimelineItem(clipID: $0.sourceID, subclipID: $0.id) }
            case .timeline:
                return nil
            }
        }
        guard !items.isEmpty else { return }
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
        // Shares the subclip until one of them is trimmed.
        let copy = TimelineItem(clipID: original.clipID, subclipID: original.subclipID, audio: original.audio)
        timeline.insert(copy, at: index + 1)
        selectedTimelineItemID = copy.id
    }

    func removeTimelineItem(_ id: UUID) {
        timeline.removeAll { $0.id == id }
        if selectedTimelineItemID == id { selectedTimelineItemID = nil }
    }

    /// Minimum length a trimmed clip can have.
    static let minimumClipLength = 0.1

    /// Trimming changes the item's subclip. A whole source video becomes a new subclip first,
    /// and a subclip used elsewhere on the timeline is copied so only this item changes.
    func setTrimStart(_ value: Double, for id: UUID) {
        guard let subclip = trimmableSubclip(for: id) else { return }
        let end = range(of: subclip).upperBound
        subclip.start = min(max(0, value), end - Self.minimumClipLength)
    }

    func setTrimEnd(_ value: Double, for id: UUID) {
        guard let subclip = trimmableSubclip(for: id), let clip = clip(for: subclip.sourceID) else { return }
        subclip.end = max(min(value, clip.duration), subclip.start + Self.minimumClipLength)
    }

    /// Plays the whole source video again. The subclip stays in the sidebar.
    func resetTrim(for id: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return }
        timeline[index].subclipID = nil
    }

    /// The subclip that trimming this timeline item should change.
    private func trimmableSubclip(for itemID: UUID) -> Subclip? {
        guard let index = timeline.firstIndex(where: { $0.id == itemID }),
              let clip = clip(for: timeline[index].clipID) else { return nil }
        let item = timeline[index]
        if let id = item.subclipID, let subclip = subclip(for: id) {
            let isShared = timeline.contains { $0.id != itemID && $0.subclipID == id }
            guard isShared else { return subclip }
            let copy = makeSubclip(of: clip, start: subclip.start, end: subclip.end, after: subclip)
            timeline[index].subclipID = copy.id
            return copy
        }
        let subclip = makeSubclip(of: clip, start: 0, end: nil)
        timeline[index].subclipID = subclip.id
        return subclip
    }

    /// Handles anything dropped on the timeline: new files, media-list rows, or reordered items.
    func handleTimelineDrop(_ urls: [URL], at index: Int) -> Bool {
        if let url = urls.first, let itemID = TimelineItem.id(fromDragURL: url) {
            moveTimelineItem(itemID, to: index)
            return true
        }
        let dragged = urls.compactMap(Subclip.id(fromDragURL:))
        if !dragged.isEmpty {
            addToTimeline(dragged.map { .subclip($0) }, at: index)
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
            return .init(url: clip.url, start: range.lowerBound, end: range.upperBound, settings: clip.enhanceSettings)
        }
    }

    /// The timeline's frame size in pixels, from its settings (Automatic uses the first clip with video).
    var timelineFrameSize: CGSize {
        let first = timeline.lazy.compactMap { self.clip(for: $0.clipID) }.first { $0.hasVideo && $0.displaySize != .zero }
        return timelineSettings.renderSize(firstClip: first?.outputSize)
    }

    /// Frames per second the timeline plays and exports at: its setting, or the fastest clip's
    /// (deinterlaced clips count double).
    var timelineFrameRate: Double {
        if let duration = timelineSettings.frameRate.frameDuration { return 1 / duration.seconds }
        let fastest = timeline.compactMap { clip(for: $0.clipID) }.filter(\.hasVideo).map(\.outputFrameRate).max() ?? 0
        return fastest > 0 ? Double(fastest) : 30
    }

    /// What a timeline export starts from, for estimating its size.
    var timelineExportSource: ExportEstimate.Source {
        let clips = timeline.compactMap { clip(for: $0.clipID) }
        let withSound = clips.filter(\.hasAudio)
        let audio: (sampleRate: Double, channels: Int)? = withSound.isEmpty ? nil : (
            withSound.compactMap(\.audioSampleRate).max() ?? 48_000,
            withSound.compactMap(\.audioChannels).max() ?? 2
        )
        return ExportEstimate.Source(frameSize: timelineFrameSize, framesPerSecond: timelineFrameRate,
                                     duration: timelineDuration, audio: audio)
    }

    func buildTimeline() async throws -> CompositionBuilder.Result {
        try await CompositionBuilder.build(timelineSegments, settings: timelineSettings,
                                           audio: TimelineAudio(spans: timelineAudioSpans))
    }

    // MARK: Loudness

    /// How a timeline item's volume works out.
    struct AudioPlan: Equatable {
        var state: LoudnessState?
        /// Decibels it's turned up or down by.
        var gainDB: Double
        /// Kept from going louder, so the loudest moments don't distort.
        var isLimited: Bool
        /// Whether it's following the timeline's target.
        var isMatching: Bool

        var measurement: Loudness.Measurement? {
            if case .measured(let measurement) = state { measurement } else { nil }
        }
        /// Its loudness after the change, in LUFS.
        var result: Double? { measurement?.integrated.map { $0 + gainDB } }
    }

    /// Identifies the sound a timeline item plays: its file and the part of it.
    func loudnessKey(for item: TimelineItem) -> String? {
        guard let clip = clip(for: item.clipID), clip.isLoaded else { return nil }
        let range = trimRange(of: item)
        return "\(clip.url.path)|\(range.lowerBound)|\(range.upperBound)"
    }

    func audioPlan(for item: TimelineItem) -> AudioPlan {
        let state = loudnessKey(for: item).flatMap { loudness[$0] }
        var plan = AudioPlan(state: state, gainDB: item.audio.adjustDB, isLimited: false,
                             isMatching: timelineSettings.matchLoudness && item.audio.matchesTarget)
        guard let measurement = plan.measurement else { return plan }
        if plan.isMatching, let integrated = measurement.integrated {
            plan.gainDB += timelineSettings.loudnessTarget - integrated
        }
        // Turning up stops 1 dB short of full scale, where the sound would distort.
        let headroom = -1 - measurement.peak
        if plan.gainDB > 0, plan.gainDB > headroom {
            plan.gainDB = max(0, headroom)
            plan.isLimited = true
        }
        plan.gainDB = min(30, max(-60, plan.gainDB))
        return plan
    }

    /// Where each item plays on the timeline and its volume change, in the order the
    /// combined video is built.
    var timelineAudioSpans: [TimelineAudio.Span] {
        var start = 0.0
        return timeline.compactMap { item in
            guard let clip = clip(for: item.clipID), clip.isLoaded else { return nil }
            let duration = self.duration(of: item)
            guard duration > 0 else { return nil }
            defer { start += duration }
            return TimelineAudio.Span(start: start, end: start + duration, gainDB: audioPlan(for: item).gainDB)
        }
    }

    /// Seconds into the timeline where an item starts, as `timelineAudioSpans` counts.
    func timelineStart(of item: TimelineItem) -> Double {
        var start = 0.0
        for other in timeline {
            if other.id == item.id { break }
            if clip(for: other.clipID)?.isLoaded == true { start += duration(of: other) }
        }
        return start
    }

    /// The parts of files the timeline plays. Measuring starts again when they change.
    var loudnessKeys: [String] {
        timeline.compactMap(loudnessKey(for:))
    }

    /// Measures every timeline item's loudness that isn't known yet, one at a time.
    func measureTimelineLoudness() async {
        for item in timeline {
            guard !Task.isCancelled else { return }
            guard let key = loudnessKey(for: item), loudness[key] == nil,
                  let clip = clip(for: item.clipID) else { continue }
            guard clip.hasAudio else {
                loudness[key] = .measured(nil)
                continue
            }
            loudness[key] = .measuring
            let url = clip.url, range = trimRange(of: item)
            do {
                let measurement = try await Task.detached(priority: .utility) {
                    try await Loudness.measure(url: url, range: range)
                }.value
                loudness[key] = .measured(measurement)
            } catch {
                loudness[key] = Task.isCancelled ? nil : .failed
            }
        }
    }

    func setAudio(_ audio: ItemAudio, for itemID: UUID) {
        guard let index = timeline.firstIndex(where: { $0.id == itemID }) else { return }
        timeline[index].audio = audio
    }

    var canExport: Bool {
        isTimelineSelected ? !timeline.isEmpty : !selectedMedia.isEmpty
    }

    /// Exports whatever is selected: the timeline, or each selected source video and subclip.
    func exportSelection(as preset: ExportPreset) {
        if isTimelineSelected {
            exportTimeline(as: preset)
        } else {
            exportMedia(selectedMedia, as: preset)
        }
    }

    /// Exports each source video (or just its in/out range when one is marked).
    func exportClips(_ clips: [Clip], as preset: ExportPreset) {
        exportMedia(clips.map { .clip($0.id) }, as: preset)
    }

    /// Exports each source video and subclip as its own file.
    func exportMedia(_ media: [SidebarItem], as preset: ExportPreset) {
        guard !media.isEmpty else { return }
        Task {
            guard let folder = await exportFolder() else { return }
            for entry in media {
                switch entry {
                case .clip(let id):
                    if let clip = clip(for: id) { await exportClip(clip, as: preset, to: folder) }
                case .subclip(let id):
                    if let subclip = subclip(for: id), let clip = clip(for: subclip.sourceID) {
                        await exportClip(clip, range: range(of: subclip), name: subclip.name, as: preset, to: folder)
                    }
                case .timeline:
                    break
                }
            }
        }
    }

    func exportClip(_ clip: Clip, as preset: ExportPreset, to folder: URL) async {
        await exportClip(clip, range: clip.hasMarks ? clip.markedRange : nil, name: clip.name, as: preset, to: folder)
    }

    /// Exports part of a source video (`range`), or all of it when `range` is `nil`.
    func exportClip(_ clip: Clip, range: ClosedRange<Double>?, name baseName: String,
                    as preset: ExportPreset, to folder: URL) async {
        let settings = clip.enhanceSettings
        let enhanced = settings.isActive && !preset.isAudioOnly
        let name = enhanced ? "\(baseName) \(clip.exportNameSuffix)" : baseName
        guard clip.isLoaded else {
            exporter.reportFailure(clip.loadError ?? "This clip is still loading. Try again in a moment.", name: name, preset: preset)
            return
        }
        let marked = range
        let range = range ?? 0...clip.duration
        do {
            if enhanced {
                let playable = try await Enhancer.makePlayable(url: clip.url, settings: settings)
                let timeRange = marked != nil
                    ? CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 90_000),
                                  end: CMTime(seconds: range.upperBound, preferredTimescale: 90_000))
                    : nil
                exporter.export(asset: playable.asset, videoComposition: playable.videoComposition,
                                timeRange: timeRange, name: name, preset: preset, folder: folder)
            } else {
                // Goes through a composition so the picture shape is corrected the same way as in the preview.
                let built = try await CompositionBuilder.build([.init(url: clip.url, start: range.lowerBound, end: range.upperBound)])
                exporter.export(asset: built.composition, videoComposition: built.videoComposition,
                                name: name, preset: preset, folder: folder)
            }
        } catch {
            exporter.reportFailure(error.localizedDescription, name: name, preset: preset)
        }
    }

    /// This project's timeline exports, for the inspector's Cancel button.
    private(set) var timelineExports: [ExportJob] = []

    var runningTimelineExports: [ExportJob] { timelineExports.filter(\.isRunning) }

    func cancelTimelineExports() {
        for job in runningTimelineExports { job.cancel() }
    }

    func exportTimeline(as preset: ExportPreset) {
        Task {
            guard let folder = await exportFolder() else { return }
            let name = "Timeline \(Date.now.formatted(.dateTime.year().month().day().hour().minute()))"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: ".")
            do {
                let result = try await buildTimeline()
                let job = exporter.export(asset: result.composition, videoComposition: result.videoComposition,
                                          audioMix: result.audioMix, name: name, preset: preset, folder: folder)
                timelineExports.removeAll { !$0.isRunning }
                timelineExports.append(job)
            } catch {
                exporter.reportFailure(error.localizedDescription, name: "Timeline", preset: preset)
            }
        }
    }

    // MARK: Hiding the sidebars

    /// Both the left sidebar and the right inspector are hidden (View › Hide Sidebars, ⌘.).
    var sidebarsHidden = false

    // MARK: Full-screen playback

    /// What the Play Full Screen button plays: set by the clip or timeline view on screen.
    struct FullScreenSource {
        let owner: UUID
        let present: () -> Void
    }

    private(set) var fullScreenSource: FullScreenSource?

    func setFullScreenSource(_ source: FullScreenSource) {
        fullScreenSource = source
    }

    /// Clears the source only if `owner` set it (the next view may already have set its own).
    func clearFullScreenSource(owner: UUID) {
        if fullScreenSource?.owner == owner { fullScreenSource = nil }
    }

    func playFullScreen() {
        fullScreenSource?.present()
    }

    // MARK: Where exports go

    /// The saved project file, or `nil` if it hasn't been saved yet.
    var projectURL: URL?

    /// The folder exports go to, following Settings. May ask the user. `nil` means cancelled.
    func exportFolder() async -> URL? {
        switch exporter.location {
        case .projectFolder:
            guard let projectURL else {
                return await chooseFolder(message: "This project hasn't been saved yet. Choose where to save the exported videos.",
                                          startingAt: exporter.lastChosenFolder)
            }
            let folder = projectURL.deletingLastPathComponent()
            if exporter.canWrite(to: folder) { return folder }
            return await chooseFolder(
                message: "To save exports next to “\(projectURL.deletingPathExtension().lastPathComponent)”, allow SwiftCut to use this folder by clicking Export Here. You only need to do this once.",
                startingAt: folder
            )
        case .ask:
            return await chooseFolder(message: "Choose where to save the exported videos.", startingAt: exporter.lastChosenFolder)
        case .folder:
            if let folder = exporter.availableCustomFolder() { return folder }
            guard exporter.customFolderPath != nil else {
                return await chooseFolder(message: "Choose where to save the exported videos.", startingAt: exporter.lastChosenFolder)
            }
            switch await ask(.missingFolder(path: exporter.customFolderPath ?? "")) {
            case .chooseFolder:
                return await chooseFolder(message: "Choose where to save the exported videos.", startingAt: nil)
            case .openSettings:
                openExportSettings?()
                return nil
            case .cancel:
                return nil
            }
        }
    }

    /// The project's folder, for saving frame images. Asks once for permission to use it
    /// (SwiftCut is sandboxed), or for a folder if the project hasn't been saved.
    /// `nil` means cancelled.
    func projectFolderForImages() async -> URL? {
        guard let projectURL else {
            return await chooseFolder(message: "This project hasn't been saved yet. Choose where to save the frame images.",
                                      startingAt: exporter.lastChosenFolder)
        }
        let folder = projectURL.deletingLastPathComponent()
        if exporter.canWrite(to: folder) { return folder }
        return await chooseFolder(
            message: "To save images next to “\(projectURL.deletingPathExtension().lastPathComponent)”, allow SwiftCut to use this folder by clicking Export Here. You only need to do this once.",
            startingAt: folder
        )
    }

    /// Shown over the project window when exports can't go where Settings says.
    enum ExportPrompt: Equatable {
        case missingFolder(path: String)
    }

    enum PromptChoice {
        case chooseFolder, openSettings, cancel
    }

    private(set) var exportPrompt: ExportPrompt?
    @ObservationIgnored
    private var promptContinuation: CheckedContinuation<PromptChoice, Never>?

    /// Opens Settings at the Export Presets page. Set by the window.
    @ObservationIgnored
    var openExportSettings: (() -> Void)?

    private func ask(_ prompt: ExportPrompt) async -> PromptChoice {
        promptContinuation?.resume(returning: .cancel)
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            exportPrompt = prompt
        }
    }

    /// The user's answer to `exportPrompt`. Only the first answer counts.
    func answerPrompt(_ choice: PromptChoice) {
        exportPrompt = nil
        promptContinuation?.resume(returning: choice)
        promptContinuation = nil
    }

    /// Asks for a folder with a standard Open panel, attached to the project window.
    /// Replaced in tests.
    @ObservationIgnored
    var folderPicker: @MainActor (_ message: String, _ start: URL?) async -> URL? = { message, start in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = message
        panel.directoryURL = start
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func chooseFolder(message: String, startingAt start: URL?) async -> URL? {
        guard let folder = await folderPicker(message, start) else { return nil }
        _ = folder.startAccessingSecurityScopedResource()
        exporter.rememberAccess(to: folder)
        exporter.lastChosenFolder = folder
        return folder
    }
}
