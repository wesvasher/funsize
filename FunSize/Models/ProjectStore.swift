import AppKit
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
            clip.bookmark = Clip.makeBookmark(for: url)
            clips.append(clip)
            result.append(clip)
            Task {
                await MediaLoader.load(clip)
                // New Apple Log clips get the conversion chosen in Settings › Color.
                if clip.logFormat != nil, clip.lutID == nil, let auto = ColorSettings.autoLUTForAppleLog,
                   LUTLibrary.shared.lut(id: auto) != nil {
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

    func removeClips(_ ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }
        timeline.removeAll { ids.contains($0.clipID) }
        selection = selection.filter {
            if case .clip(let id) = $0 { return !ids.contains(id) }
            return true
        }
    }

    // MARK: Saving and opening

    /// Everything a project file stores, built from the current state.
    var projectFile: ProjectFile {
        ProjectFile(
            clips: clips.map(\.record),
            timeline: timeline.map { .init(id: $0.id, clipID: $0.clipID, trimStart: $0.trimStart, trimEnd: $0.trimEnd) }
        )
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

        let items = file.timeline.map {
            TimelineItem(id: $0.id, clipID: $0.clipID, trimStart: $0.trimStart, trimEnd: $0.trimEnd)
        }
        if items != timeline { timeline = items }

        let ids = Set(clips.map(\.id))
        let kept = selection.filter {
            if case .clip(let id) = $0 { return ids.contains(id) }
            return true
        }
        if kept != selection { selection = kept }
        if let selected = selectedTimelineItemID, !timeline.contains(where: { $0.id == selected }) {
            selectedTimelineItemID = nil
        }
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
    func exportSelection(as preset: ExportPreset) {
        if isTimelineSelected {
            exportTimeline(as: preset)
        } else {
            exportClips(selectedClips, as: preset)
        }
    }

    /// Exports each clip (or just its in/out range when one is marked).
    func exportClips(_ clips: [Clip], as preset: ExportPreset) {
        guard !clips.isEmpty else { return }
        Task {
            guard let folder = await exportFolder() else { return }
            for clip in clips {
                await exportClip(clip, as: preset, to: folder)
            }
        }
    }

    func exportClip(_ clip: Clip, as preset: ExportPreset, to folder: URL) async {
        let settings = clip.enhanceSettings
        let enhanced = settings.isActive && !preset.isAudioOnly
        let name = enhanced ? "\(clip.name) \(clip.exportNameSuffix)" : clip.name
        guard clip.isLoaded else {
            exporter.reportFailure(clip.loadError ?? "This clip is still loading. Try again in a moment.", name: name, preset: preset)
            return
        }
        let range = clip.markedRange
        do {
            if enhanced {
                let playable = try await Enhancer.makePlayable(url: clip.url, settings: settings)
                let timeRange = clip.hasMarks
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

    func exportTimeline(as preset: ExportPreset) {
        Task {
            guard let folder = await exportFolder() else { return }
            let name = "Timeline \(Date.now.formatted(.dateTime.year().month().day().hour().minute()))"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: ".")
            do {
                let result = try await buildTimeline()
                exporter.export(asset: result.composition, videoComposition: result.videoComposition,
                                name: name, preset: preset, folder: folder)
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
                message: "To save exports next to “\(projectURL.deletingPathExtension().lastPathComponent)”, allow FunSize to use this folder by clicking Export Here. You only need to do this once.",
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
