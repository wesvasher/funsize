import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import FunSize

/// Reads what an exported file actually contains.
private struct FileInfo {
    var videoSize: CGSize?
    var frameRate: Float?
    var videoCodec: FourCharCode?
    var audioRate: Double?
    var audioChannels: Int?
    var audioFormat: AudioFormatID?
    var audioBits: Int?
    var duration: Double

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        duration = try await asset.load(.duration).seconds
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (size, rate, formats) = try await video.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
            videoSize = size
            frameRate = rate
            videoCodec = formats.first.map(CMFormatDescriptionGetMediaSubType)
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            audioRate = asbd.mSampleRate
            audioChannels = Int(asbd.mChannelsPerFrame)
            audioFormat = asbd.mFormatID
            audioBits = Int(asbd.mBitsPerChannel)
        }
    }
}

private func export(_ source: URL, _ preset: ExportPreset, in dir: URL) async throws -> (ExportJob, FileInfo) {
    let built = try await CompositionBuilder.build([.init(url: source, start: 0, end: try await AVURLAsset(url: source).load(.duration).seconds)])
    let job = ExportManager.test().export(asset: built.composition, videoComposition: built.videoComposition,
                                          name: "out", preset: preset, folder: dir)
    await job.task?.value
    #expect(job.state == .finished, "\(preset.name): \(job.state)")
    return (job, try await FileInfo(job.outputURL))
}

struct ExportPresetExportTests {
    @Test(arguments: ExportPreset.defaults)
    func builtInPresetsExport(preset: ExportPreset) async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "src", seconds: 1, size: CGSize(width: 640, height: 360), audio: true)
        let (job, info) = try await export(source, preset, in: dir)

        #expect(job.outputURL.pathExtension == preset.container.fileExtension)
        #expect(abs(info.duration - 1) < 0.1)
        #expect(info.audioRate == 48_000)
        if preset.isAudioOnly {
            #expect(info.videoSize == nil)
        } else {
            #expect(info.videoSize == CGSize(width: 640, height: 360))
            #expect(info.videoCodec == preset.video.map { CMVideoCodecType(fourCC: $0.codec.avCodec.rawValue) })
        }
    }

    @Test func fitWithinKeepsShapeAndOnlyEnlargesWhenAsked() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "sd", seconds: 1, size: CGSize(width: 640, height: 480))
        var preset = ExportPreset.builtIn("1080p MP4")

        let (_, kept) = try await export(source, preset, in: dir)
        #expect(kept.videoSize == CGSize(width: 640, height: 480))

        preset.video?.enlarges = true
        let (_, enlarged) = try await export(source, preset, in: dir)
        #expect(enlarged.videoSize == CGSize(width: 1440, height: 1080))
    }

    @Test func exactSizeAndFrameRateAndBitRate() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "src", seconds: 2, size: CGSize(width: 640, height: 480))
        var preset = ExportPreset.builtIn("MP4 (H.264)")
        preset.video?.frameSize = .exact
        preset.video?.width = 1280
        preset.video?.height = 720
        preset.video?.frameRate = 24
        preset.video?.rateControl = .bitRate
        preset.video?.bitRateMbps = 4
        preset.video?.keyframeInterval = 24

        let (_, info) = try await export(source, preset, in: dir)
        #expect(info.videoSize == CGSize(width: 1280, height: 720))
        #expect(abs((info.frameRate ?? 0) - 24) < 0.1)
        #expect(abs(info.duration - 2) < 0.1)
    }

    @Test func standardDefinitionComesOutSquare() async throws {
        // 720×480 stored, 10:11 pixels, 704 clean aperture: shown at 640×480.
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "dv", seconds: 1, size: CGSize(width: 720, height: 480),
                                              pixelAspect: (10, 11), cleanApertureWidth: 704)
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = try #require(store.importFiles([source]).first)
        await MediaLoader.load(clip)
        await store.exportClip(clip, as: .builtIn("ProRes 422"), to: dir)
        let job = try #require(store.exporter.jobs.first)
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")
        #expect(try await FileInfo(job.outputURL).videoSize == CGSize(width: 640, height: 480))
    }

    @Test func audioFormats() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "src", seconds: 1, size: CGSize(width: 320, height: 240), audio: true)

        var wav = ExportPreset(name: "WAV", fileSuffix: "WAV", container: .wav, video: nil,
                               audio: .init(codec: .pcm, bitDepth: 24, sampleRate: 44_100, channels: 1))
        wav.normalize()
        let (_, pcm) = try await export(source, wav, in: dir)
        #expect(pcm.audioFormat == kAudioFormatLinearPCM)
        #expect(pcm.audioBits == 24 && pcm.audioRate == 44_100 && pcm.audioChannels == 1)
        #expect(pcm.videoSize == nil)

        let lossless = ExportPreset(name: "ALAC", fileSuffix: "ALAC", container: .m4a, video: nil, audio: .init(codec: .alac))
        let (_, alac) = try await export(source, lossless, in: dir)
        #expect(alac.audioFormat == kAudioFormatAppleLossless)

        var silent = ExportPreset.builtIn("MP4 (H.264)")
        silent.audio = nil
        let (_, noSound) = try await export(source, silent, in: dir)
        #expect(noSound.audioRate == nil && noSound.videoSize != nil)
    }

    /// Cancels at different moments, including right away, since cancelling mid-read used to crash.
    @Test func cancellingRemovesThePartialFile() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "long", seconds: 6, size: CGSize(width: 1280, height: 720), audio: true)
        let manager = ExportManager.test()
        for delay in [0, 5, 20, 60, 150, 300] {
            let job = manager.export(asset: AVURLAsset(url: source), name: "out", preset: .builtIn("ProRes 422"), folder: dir)
            try await Task.sleep(for: .milliseconds(delay))
            job.cancel()
            await job.task?.value
            #expect(job.state == .cancelled || job.state == .finished, "\(delay) ms: \(job.state)")
            if job.state == .cancelled {
                #expect(!FileManager.default.fileExists(atPath: job.outputURL.path(percentEncoded: false)))
            }
        }
    }

    @Test func audioOnlyPresetOnSilentClipFailsClearly() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "silent", seconds: 1, size: CGSize(width: 320, height: 240))
        let job = ExportManager.test().export(asset: AVURLAsset(url: source), name: "out", preset: .builtIn("Audio Only (M4A)"), folder: dir)
        await job.task?.value
        guard case .failed(let message) = job.state else {
            Issue.record("Expected failure, got \(job.state)")
            return
        }
        #expect(message.contains("nothing this preset can export"))
    }

    @Test func exportsCombinedTimeline() async throws {
        let dir = try TestVideo.tempDirectory()
        let a = try await TestVideo.make(in: dir, name: "a", seconds: 1, size: CGSize(width: 640, height: 360), audio: true)
        let b = try await TestVideo.make(in: dir, name: "b", seconds: 1, size: CGSize(width: 360, height: 640))
        let built = try await CompositionBuilder.build([.init(url: a, start: 0, end: 1), .init(url: b, start: 0, end: 1)])
        let job = ExportManager.test().export(asset: built.composition, videoComposition: built.videoComposition,
                                              name: "timeline", preset: .builtIn("MP4 (H.264)"), folder: dir)
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")
        let info = try await FileInfo(job.outputURL)
        #expect(abs(info.duration - 2) < 0.1)
        #expect(info.videoSize == CGSize(width: 640, height: 360))
    }

    @Test func ntscRatesUseExactTiming() {
        #expect(ExportPreset.frameDuration(fps: 29.97) == CMTime(value: 1001, timescale: 30000))
        #expect(ExportPreset.frameDuration(fps: 59.94) == CMTime(value: 1001, timescale: 60000))
        #expect(ExportPreset.frameDuration(fps: 23.976) == CMTime(value: 1001, timescale: 24000))
        #expect(ExportPreset.frameDuration(fps: 30) == CMTime(value: 1, timescale: 30))
        #expect(ExportPreset.frameDuration(fps: 25) == CMTime(value: 1, timescale: 25))
    }
}

private extension CMVideoCodecType {
    init(fourCC string: String) {
        self = string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}

@Suite(.serialized)
struct ExportPresetLibraryTests {
    @Test func startsWithBuiltInsAndSavesChanges() {
        let manager = ExportManager.test("FunSizeTests.library")
        #expect(manager.presets == ExportPreset.defaults)

        var custom = ExportPreset.builtIn("MP4 (H.264)").copy(named: "Mine")
        custom.container = .wav
        manager.save(custom)
        // Saving fixes settings that don't fit the file type.
        #expect(manager.preset(id: custom.id)?.video == nil)
        #expect(manager.preset(id: custom.id)?.audio?.codec == .pcm)

        let reopened = ExportManager(defaults: UserDefaults(suiteName: "FunSizeTests.library")!)
        #expect(reopened.presets.count == ExportPreset.defaults.count + 1)
        #expect(reopened.presets.last?.name == "Mine")
    }

    @Test func duplicateDeleteAndRestore() {
        let manager = ExportManager.test("FunSizeTests.library")
        let first = manager.presets[0]
        let copy = try! #require(manager.duplicatePreset(first.id))
        #expect(copy.name == "\(first.name) Copy")
        #expect(manager.duplicatePreset(first.id)?.name == "\(first.name) Copy 2")

        var changed = first
        changed.fileSuffix = "Changed"
        manager.save(changed)
        manager.deletePresets([ExportPreset.defaults[1].id])
        manager.restoreDefaultPresets()
        #expect(manager.preset(id: first.id)?.fileSuffix == first.fileSuffix)
        #expect(manager.preset(id: ExportPreset.defaults[1].id) != nil)
        #expect(manager.preset(id: copy.id) != nil)  // the user's own presets stay
    }

    @Test func presetFilesRoundTripAndImportUpdatesMatches() throws {
        let manager = ExportManager.test("FunSizeTests.library")
        let mine = ExportPreset.builtIn("720p MP4").copy(named: "Shared")
        let data = try JSONEncoder().encode(PresetFile(presets: [mine, ExportPreset.defaults[0]]))
        let read = try PresetsDocument.decode(data)
        #expect(read == [mine, ExportPreset.defaults[0]])

        let counts = manager.importPresets(read)
        #expect(counts.added == 1 && counts.replaced == 1)
        #expect(manager.presets.count == ExportPreset.defaults.count + 1)

        // A file with one bare preset works too.
        let single = try PresetsDocument.decode(JSONEncoder().encode(mine))
        #expect(single == [mine])
        #expect(throws: (any Error).self) { try PresetsDocument.decode(Data("{}".utf8)) }
    }
}

@Suite(.serialized)
struct ExportLocationTests {
    private func store(_ location: ExportLocation) -> (ProjectStore, Recorder) {
        let manager = ExportManager.test("FunSizeTests.location")
        manager.location = location
        let store = ProjectStore(exporter: manager)
        let recorder = Recorder()
        store.folderPicker = { message, start in
            recorder.messages.append(message)
            recorder.starts.append(start)
            return recorder.answer
        }
        store.openExportSettings = { recorder.openedSettings = true }
        return (store, recorder)
    }

    final class Recorder {
        var messages: [String] = []
        var starts: [URL?] = []
        var answer: URL?
        var openedSettings = false
    }

    @Test func savedProjectExportsNextToIt() async throws {
        let dir = try TestVideo.tempDirectory()
        let (store, recorder) = store(.projectFolder)
        store.projectURL = dir.appending(path: "Trip.funsize")
        #expect(await store.exportFolder()?.standardizedFileURL == dir.standardizedFileURL)
        #expect(recorder.messages.isEmpty)
    }

    @Test func unsavedProjectAsks() async throws {
        let dir = try TestVideo.tempDirectory()
        let (store, recorder) = store(.projectFolder)
        recorder.answer = dir
        #expect(await store.exportFolder() == dir)
        #expect(recorder.messages.first?.contains("hasn't been saved") == true)
    }

    @Test func askEachTimeAsksAndStartsWhereItLeftOff() async throws {
        let dir = try TestVideo.tempDirectory()
        let (store, recorder) = store(.ask)
        recorder.answer = dir
        _ = await store.exportFolder()
        _ = await store.exportFolder()
        #expect(recorder.messages.count == 2)
        #expect(recorder.starts.last == dir)
    }

    @Test func chosenFolderIsUsedAndMissingFolderPrompts() async throws {
        let dir = try TestVideo.tempDirectory()
        let folder = dir.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (store, recorder) = store(.folder)
        store.exporter.setCustomFolder(folder)
        #expect(await store.exportFolder()?.standardizedFileURL == folder.standardizedFileURL)

        try FileManager.default.removeItem(at: folder)
        #expect(store.exporter.customFolderIsMissing)

        // Open Settings.
        async let settingsAnswer = store.exportFolder()
        try await waitForPrompt(store)
        #expect(store.exportPrompt == .missingFolder(path: folder.path(percentEncoded: false)))
        store.answerPrompt(.openSettings)
        #expect(await settingsAnswer == nil)
        #expect(recorder.openedSettings)

        // Choose a folder for this export instead.
        recorder.answer = dir
        async let chosen = store.exportFolder()
        try await waitForPrompt(store)
        store.answerPrompt(.chooseFolder)
        #expect(await chosen == dir)
        #expect(store.exportPrompt == nil)
    }

    private func waitForPrompt(_ store: ProjectStore) async throws {
        for _ in 0..<100 where store.exportPrompt == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(store.exportPrompt != nil)
    }
}

@Suite(.serialized)
struct SettingsWindowTests {
    @Test(arguments: SettingsPage.allCases)
    func pageLaysOut(page: SettingsPage) async throws {
        let saved = UserDefaults.standard.string(forKey: SettingsPage.storageKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsPage.storageKey) }
        UserDefaults.standard.set(page.rawValue, forKey: SettingsPage.storageKey)

        let manager = ExportManager.test("FunSizeTests.settings")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView().environment(manager))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for location in ExportLocation.allCases {
            manager.location = location
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    @Test func editorLaysOutForEveryFileType() async throws {
        for container in ExportPreset.Container.allCases {
            var preset = ExportPreset.builtIn("MP4 (H.264)")
            preset.container = container
            preset.normalize()
            let host = NSHostingView(rootView: ExportPresetEditor(preset: preset, isNew: false) { _ in })
            host.frame = CGRect(x: 0, y: 0, width: 520, height: 640)
            host.layoutSubtreeIfNeeded()
            host.display()
        }
    }
}
