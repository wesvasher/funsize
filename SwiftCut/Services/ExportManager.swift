import AppKit
import AVFoundation
import Observation

/// One running or finished export, shown in the Exports popover.
@Observable
final class ExportJob: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let name: String
    let presetName: String
    let systemImage: String
    let outputURL: URL
    var progress: Double = 0
    var state: State = .running
    var task: Task<Void, Never>?

    init(name: String, preset: ExportPreset, outputURL: URL) {
        self.name = name
        self.presetName = preset.name
        self.systemImage = preset.systemImage
        self.outputURL = outputURL
    }

    var isRunning: Bool { state == .running }

    func cancel() {
        task?.cancel()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }
}

/// Where exports go when no folder is given.
enum ExportLocation: String, CaseIterable, Identifiable {
    /// The folder holding the project file. Unsaved projects ask.
    case projectFolder
    /// Ask every time.
    case ask
    /// Always one chosen folder.
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectFolder: "Next to the project file"
        case .ask: "Ask each time"
        case .folder: "Always in this folder:"
        }
    }
}

/// Runs exports, keeps the export presets, and remembers where exports go.
@Observable
final class ExportManager {
    private enum Key {
        static let location = "exportLocation"
        static let folderBookmark = "exportFolderBookmark"
        static let folderPath = "exportFolderPath"
        static let reveal = "revealWhenFinished"
        static let presets = "exportPresets"
        static let grantedFolders = "grantedFolders"
    }

    private let defaults: UserDefaults

    var jobs: [ExportJob] = []
    var isShowingActivity = false

    var revealWhenFinished: Bool {
        didSet { defaults.set(revealWhenFinished, forKey: Key.reveal) }
    }

    /// `defaults` is replaceable so tests don't touch the real settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        revealWhenFinished = defaults.bool(forKey: Key.reveal)

        if let data = defaults.data(forKey: Key.presets),
           let saved = try? JSONDecoder().decode([ExportPreset].self, from: data) {
            presets = saved
        } else {
            presets = ExportPreset.defaults
        }

        var path = defaults.string(forKey: Key.folderPath)
        var folder: URL?
        if let data = defaults.data(forKey: Key.folderBookmark) {
            var stale = false
            folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
            if path == nil { path = folder?.path(percentEncoded: false) }
        }
        customFolder = folder
        customFolderPath = path

        if let raw = defaults.string(forKey: Key.location), let saved = ExportLocation(rawValue: raw) {
            location = saved
        } else {
            // Someone who picked a folder before this setting existed keeps using it.
            location = path != nil ? .folder : .projectFolder
        }
    }

    var runningJobs: [ExportJob] { jobs.filter(\.isRunning) }

    var overallProgress: Double {
        let running = runningJobs
        guard !running.isEmpty else { return 1 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    // MARK: Presets

    var presets: [ExportPreset] {
        didSet { savePresets() }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Key.presets)
        }
    }

    func preset(id: ExportPreset.ID) -> ExportPreset? {
        presets.first { $0.id == id }
    }

    /// Adds a preset, or replaces the one with the same id.
    func save(_ preset: ExportPreset) {
        let preset = preset.normalized
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
    }

    func deletePresets(_ ids: Set<ExportPreset.ID>) {
        presets.removeAll { ids.contains($0.id) }
    }

    func duplicatePreset(_ id: ExportPreset.ID) -> ExportPreset? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = presets[index].copy(named: uniqueName("\(presets[index].name) Copy"))
        presets.insert(copy, at: index + 1)
        return copy
    }

    /// Adds imported presets. A preset that's already here (same id) is updated.
    @discardableResult
    func importPresets(_ imported: [ExportPreset]) -> (added: Int, replaced: Int) {
        var added = 0, replaced = 0
        var updated = presets
        for preset in imported {
            if let index = updated.firstIndex(where: { $0.id == preset.id }) {
                updated[index] = preset
                replaced += 1
            } else {
                updated.append(preset)
                added += 1
            }
        }
        presets = updated
        return (added, replaced)
    }

    /// Puts back the built-in presets as they came. The user's own presets stay.
    func restoreDefaultPresets() {
        var updated = presets
        for preset in ExportPreset.defaults {
            if let index = updated.firstIndex(where: { $0.id == preset.id }) {
                updated[index] = preset
            } else {
                updated.append(preset)
            }
        }
        presets = updated
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(presets.map(\.name))
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: Destination

    var location: ExportLocation {
        didSet { defaults.set(location.rawValue, forKey: Key.location) }
    }

    /// The folder chosen for "Always in this folder".
    private(set) var customFolder: URL?
    /// Its path when it was chosen, to describe it even if it's gone.
    private(set) var customFolderPath: String?

    /// The chosen folder, if it's still there (not deleted, renamed away, or on a disconnected drive).
    /// Starts access to it.
    func availableCustomFolder() -> URL? {
        if let data = defaults.data(forKey: Key.folderBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                customFolder = url
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                    defaults.set(fresh, forKey: Key.folderBookmark)
                }
            } else {
                customFolder = nil
            }
        }
        guard let folder = customFolder else { return nil }
        _ = folder.startAccessingSecurityScopedResource()
        guard Self.isUsableFolder(folder) else { return nil }
        return folder
    }

    var customFolderIsMissing: Bool {
        guard let folder = customFolder else { return customFolderPath != nil }
        return !Self.isUsableFolder(folder)
    }

    static func isUsableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return !url.pathComponents.contains(".Trash")
    }

    /// Asks for the "Always in this folder" folder (used in Settings).
    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder SwiftCut always saves exported videos to."
        if let customFolder, Self.isUsableFolder(customFolder) { panel.directoryURL = customFolder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCustomFolder(url)
    }

    func setCustomFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(data, forKey: Key.folderBookmark)
        }
        customFolder = url
        customFolderPath = url.path(percentEncoded: false)
        defaults.set(customFolderPath, forKey: Key.folderPath)
        location = .folder
    }

    /// The last folder picked when asked, to start the next panel there.
    var lastChosenFolder: URL?

    /// SwiftCut is sandboxed, so it can only write where the user has allowed it.
    /// Folders picked in a panel are remembered so they only need allowing once.
    func canWrite(to folder: URL) -> Bool {
        var granted = defaults.dictionary(forKey: Key.grantedFolders) as? [String: Data] ?? [:]
        let key = folder.standardizedFileURL.path(percentEncoded: false)
        if let data = granted[key] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
            } else {
                granted[key] = nil
                defaults.set(granted, forKey: Key.grantedFolders)
            }
        }
        let probe = folder.appending(path: ".swiftcut-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path(percentEncoded: false), contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Remembers a folder the user picked, so it can be written to after relaunching.
    func rememberAccess(to folder: URL) {
        guard let data = try? folder.bookmarkData(options: .withSecurityScope) else { return }
        var granted = defaults.dictionary(forKey: Key.grantedFolders) as? [String: Data] ?? [:]
        granted[folder.standardizedFileURL.path(percentEncoded: false)] = data
        defaults.set(granted, forKey: Key.grantedFolders)
    }

    // MARK: Exporting

    @discardableResult
    func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition? = nil,
        timeRange: CMTimeRange? = nil,
        name: String,
        preset: ExportPreset,
        folder: URL
    ) -> ExportJob {
        let outputURL = uniqueURL(in: folder, base: "\(name) - \(preset.fileSuffix)", ext: preset.container.fileExtension)
        let job = ExportJob(name: name, preset: preset, outputURL: outputURL)
        jobs.insert(job, at: 0)
        isShowingActivity = true

        let transcoder = Transcoder(asset: asset, videoComposition: videoComposition, timeRange: timeRange,
                                    preset: preset, outputURL: outputURL)
        job.task = Task {
            do {
                try await transcoder.run { progress in
                    Task { @MainActor in
                        if job.isRunning, abs(progress - job.progress) >= 0.005 || progress == 1 { job.progress = progress }
                    }
                }
                job.progress = 1
                job.state = .finished
                if revealWhenFinished { job.revealInFinder() }
            } catch is CancellationError {
                job.state = .cancelled
                try? FileManager.default.removeItem(at: outputURL)
            } catch {
                job.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        return job
    }

    /// Shows a failure in the Exports list without running anything.
    func reportFailure(_ message: String, name: String, preset: ExportPreset) {
        let job = ExportJob(name: name, preset: preset, outputURL: URL(filePath: "/\(name)"))
        job.state = .failed(message)
        jobs.insert(job, at: 0)
        isShowingActivity = true
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }

    /// "Name - MP4.mp4", then "Name - MP4 2.mp4", and so on.
    private func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appending(path: "\(base).\(ext)")
        var counter = 2
        let taken = Set(jobs.filter(\.isRunning).map(\.outputURL))
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) || taken.contains(candidate) {
            candidate = folder.appending(path: "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
