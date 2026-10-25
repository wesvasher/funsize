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
    let format: ExportFormat
    let outputURL: URL
    var progress: Double = 0
    var state: State = .running
    var task: Task<Void, Never>?

    init(name: String, format: ExportFormat, outputURL: URL) {
        self.name = name
        self.format = format
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

/// Runs exports and remembers where they go.
@Observable
final class ExportManager {
    private static let bookmarkKey = "exportFolderBookmark"
    private static let revealKey = "revealWhenFinished"

    var jobs: [ExportJob] = []
    var isShowingActivity = false

    /// A folder the user picked in Settings, or `nil` for ~/Movies/FunSize.
    private(set) var customFolder: URL?

    var revealWhenFinished: Bool {
        didSet { UserDefaults.standard.set(revealWhenFinished, forKey: Self.revealKey) }
    }

    init() {
        revealWhenFinished = UserDefaults.standard.bool(forKey: Self.revealKey)
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            customFolder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        }
    }

    var runningJobs: [ExportJob] { jobs.filter(\.isRunning) }

    var overallProgress: Double {
        let running = runningJobs
        guard !running.isEmpty else { return 1 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    // MARK: Destination

    static var defaultFolder: URL {
        realHomeDirectory.appending(path: "Movies/FunSize", directoryHint: .isDirectory)
    }

    var destinationFolder: URL { customFolder ?? Self.defaultFolder }

    /// The user's real home folder (not the sandbox container).
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where FunSize saves exported videos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        customFolder = url
    }

    func resetDestinationFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        customFolder = nil
    }

    func revealDestinationFolder() {
        NSWorkspace.shared.open(destinationFolder)
    }

    // MARK: Exporting

    @discardableResult
    func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition? = nil,
        timeRange: CMTimeRange? = nil,
        name: String,
        format: ExportFormat,
        folder: URL? = nil
    ) -> ExportJob? {
        let folder = folder ?? destinationFolder
        let scoped = folder == customFolder && folder.startAccessingSecurityScopedResource()

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            if scoped { folder.stopAccessingSecurityScopedResource() }
            report(failure: error, name: name, format: format, folder: folder)
            return nil
        }

        let outputURL = uniqueURL(in: folder, base: "\(name) - \(format.fileSuffix)", ext: format.fileExtension)
        let job = ExportJob(name: name, format: format, outputURL: outputURL)
        jobs.insert(job, at: 0)
        isShowingActivity = true

        guard let session = AVAssetExportSession(asset: asset, presetName: format.presetName) else {
            job.state = .failed("This format isn't available for this video.")
            if scoped { folder.stopAccessingSecurityScopedResource() }
            return job
        }
        if !format.isAudioOnly {
            session.videoComposition = videoComposition
        }
        if let timeRange {
            session.timeRange = timeRange
        }

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let progress) = state {
                    job.progress = progress.fractionCompleted
                }
            }
        }

        job.task = Task {
            defer {
                progressTask.cancel()
                if scoped { folder.stopAccessingSecurityScopedResource() }
            }
            do {
                try await session.export(to: outputURL, as: format.fileType)
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

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }

    private func report(failure error: Error, name: String, format: ExportFormat, folder: URL) {
        let job = ExportJob(name: name, format: format, outputURL: folder)
        job.state = .failed(error.localizedDescription)
        jobs.insert(job, at: 0)
        isShowingActivity = true
    }

    /// "Name - MP4.mp4", then "Name - MP4 2.mp4", and so on.
    private func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
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
