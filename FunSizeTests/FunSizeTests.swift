import AVFoundation
import Foundation
import Testing
@testable import FunSize

struct CompositionTests {
    @Test func combinesClipsInOrder() async throws {
        let dir = try TestVideo.tempDirectory()
        let a = try await TestVideo.make(in: dir, name: "a", seconds: 2, size: CGSize(width: 640, height: 360))
        let b = try await TestVideo.make(in: dir, name: "b", seconds: 3, size: CGSize(width: 320, height: 240))

        let result = try await CompositionBuilder.build([
            .init(url: a, start: 0, end: 2),
            .init(url: b, start: 0.5, end: 2.5),
        ])

        #expect(abs(result.duration - 4) < 0.05)
        #expect(result.videoComposition?.renderSize == CGSize(width: 640, height: 360))
    }

    @Test func emptyTimelineThrows() async {
        await #expect(throws: CompositionBuilder.BuildError.self) {
            try await CompositionBuilder.build([])
        }
    }

    @Test func fitTransformLetterboxes() {
        let t = CompositionBuilder.fitTransform(
            natural: CGSize(width: 320, height: 240),
            preferred: .identity,
            into: CGSize(width: 640, height: 360)
        )
        let rect = CGRect(x: 0, y: 0, width: 320, height: 240).applying(t)
        #expect(abs(rect.height - 360) < 0.01)
        #expect(abs(rect.midX - 320) < 0.01)
    }
}

struct StoreTests {
    @Test func reorderAndTrim() {
        let store = ProjectStore(exporter: ExportManager.test())
        let a = Clip(url: URL(fileURLWithPath: "/tmp/a.mov")); a.duration = 10
        let b = Clip(url: URL(fileURLWithPath: "/tmp/b.mov")); b.duration = 5
        store.clips = [a, b]
        store.addToTimeline([a, b])

        let first = store.timeline[0].id
        store.moveTimelineItem(first, to: 2)
        #expect(store.timeline.map(\.clipID) == [b.id, a.id])

        store.setTrimStart(2, for: first)
        store.setTrimEnd(6, for: first)
        #expect(store.timelineDuration == 9)

        store.setTrimEnd(1, for: first) // can't end before the start
        #expect(store.trimRange(of: store.timeline[1]).upperBound > 2)
    }
}

/// Writes short solid-color videos for tests.
enum TestVideo {
    /// One folder for all test files. It's emptied at the start of each test run so videos don't pile up.
    private static let root: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "FunSizeTests", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    static func tempDirectory() throws -> URL {
        let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func make(
        in dir: URL, name: String, seconds: Int, size: CGSize, fps: Int32 = 30,
        codec: AVVideoCodecType = .h264,
        pixelAspect: (Int, Int)? = nil,
        cleanApertureWidth: Int? = nil,
        transform: CGAffineTransform = .identity,
        audio: Bool = false,
        draw: ((_ frame: Int, _ pixels: CVPixelBuffer) -> Void)? = nil
    ) async throws -> URL {
        let url = dir.appending(path: "\(name).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if let (h, v) = pixelAspect {
            settings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: h,
                AVVideoPixelAspectRatioVerticalSpacingKey: v,
            ]
        }
        if let cleanApertureWidth {
            settings[AVVideoCleanApertureKey] = [
                AVVideoCleanApertureWidthKey: cleanApertureWidth,
                AVVideoCleanApertureHeightKey: Int(size.height),
                AVVideoCleanApertureHorizontalOffsetKey: 0,
                AVVideoCleanApertureVerticalOffsetKey: 0,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        let sound = audio ? TestAudio() : nil
        if let sound { writer.add(sound.input) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Feed whichever track the writer is ready for; it interleaves them and stalls one
        // track until the other catches up.
        let frames = Int(fps) * seconds
        var frame = 0, soundFrame = 0
        var videoDone = false, soundDone = false
        while frame < frames || (sound != nil && soundFrame < frames) {
            var progressed = false
            if frame < frames, input.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                let pixels = try #require(buffer)
                if let draw {
                    draw(frame, pixels)
                } else {
                    CVPixelBufferLockBaseAddress(pixels, [])
                    let shade = UInt8(frame * 4 % 255)
                    memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetDataSize(pixels))
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                }
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                frame += 1
                progressed = true
            }
            if let sound, soundFrame < frames, sound.input.isReadyForMoreMediaData {
                try sound.appendChunk(frame: soundFrame, fps: Int(fps))
                soundFrame += 1
                progressed = true
            }
            // A finished track must say so, or the writer keeps waiting for it.
            if frame == frames, !videoDone { input.markAsFinished(); videoDone = true }
            if let sound, soundFrame == frames, !soundDone { sound.input.markAsFinished(); soundDone = true }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
}

import SwiftUI

/// Draws the player screens offscreen. SwiftUI's VideoPlayer crashed here on macOS 27.
struct PlayerViewTests {
    @Test func clipAndTimelineScreensRender() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 1, size: CGSize(width: 640, height: 360))
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = try #require(store.importFiles([url]).first)
        store.addToTimeline([clip])

        for screen in [AnyView(ClipDetailView(clip: clip)), AnyView(TimelineDetailView())] {
            let host = NSHostingView(rootView: screen.environment(store).environment(store.exporter))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            host.layoutSubtreeIfNeeded()
            host.display()
        }
        try await Task.sleep(for: .milliseconds(300))
    }
}

struct InOutTests {
    @Test func timecodeAndFrameNumbers() {
        let clock = FrameClock(fps: 24)
        #expect(clock.timecode(frames: 0) == "00:00:00")
        #expect(clock.timecode(frames: 24 * 75 + 5) == "01:15:05")
        #expect(clock.timecode(frames: 24 * 3600) == "1:00:00:00")
        #expect(clock.frameIndex(at: 1.0 / 24) == 1)
        #expect(clock.frameCount(duration: 10) == 240)
    }

    @Test func markingInAndOut() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 2, size: CGSize(width: 320, height: 240))
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)

        controller.currentTime = 0.5
        #expect(controller.currentFrameNumber == 16)  // 30 fps: frame 16 starts at 0.5s
        controller.markIn()
        controller.currentTime = 1.0
        controller.markOut()
        #expect(clip.inPoint == 0.5)
        #expect(abs((clip.outPoint ?? 0) - 31.0 / 30) < 0.0001)  // out includes the frame on screen

        // Marking in after the out point clears the out point.
        controller.currentTime = 1.5
        controller.markIn()
        #expect(clip.outPoint == nil)
    }

    @Test func exportUsesMarkedRange() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 3, size: CGSize(width: 320, height: 240))
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = try #require(store.importFiles([url]).first)
        await MediaLoader.load(clip)
        clip.inPoint = 1
        clip.outPoint = 2

        store.addToTimeline([clip])
        #expect(store.timelineDuration == 1)

        let job = store.exporter.export(
            asset: AVURLAsset(url: url),
            timeRange: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 2, preferredTimescale: 600)),
            name: "clip", preset: .builtIn("MP4 (H.264)"), folder: dir
        )
        await job.task?.value
        let duration = try await AVURLAsset(url: job.outputURL).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)
    }
}

struct HandleAndKeyTests {
    private func loadedController(seconds: Int = 2) async throws -> (ClipPlayerController, Clip) {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: seconds, size: CGSize(width: 320, height: 240))
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        return (controller, clip)
    }

    @Test func handlesSnapToFramesAndCantCross() async throws {
        let (controller, clip) = try await loadedController()
        clip.inPoint = 0.5
        clip.outPoint = 1.5

        controller.dragIn(to: 0.71)  // 30 fps: nearest boundary is frame 21
        #expect(clip.inPoint == 21.0 / 30)
        #expect(controller.currentTime == 21.0 / 30)  // preview shows the new in frame

        controller.dragIn(to: 1.9)  // can't pass the out point
        #expect(abs(clip.inPoint! - 44.0 / 30) < 0.0001)

        controller.dragOut(to: 0.1)  // can't pass the in point
        #expect(abs(clip.outPoint! - 45.0 / 30) < 0.0001)
        #expect(abs(controller.currentTime - 44.0 / 30) < 0.0001)  // preview shows the last included frame

        controller.dragOut(to: 99)  // clamps to the end
        #expect(clip.outPoint == clip.duration)
    }

    @Test func keyboardShortcuts() async throws {
        let (controller, clip) = try await loadedController()
        func press(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
            )!
            return PlaybackKeyMonitor.perform(event, on: controller)
        }

        #expect(press(" ", keyCode: 49))
        #expect(controller.isPlaying)
        #expect(press(" ", keyCode: 49))
        #expect(!controller.isPlaying)

        controller.seek(to: 0.5)
        #expect(press("i", keyCode: 34))
        #expect(clip.inPoint == 0.5)
        #expect(press("→", keyCode: 124))
        #expect(controller.currentFrameNumber == 17)
        #expect(press("o", keyCode: 31))
        #expect(clip.outPoint != nil)

        #expect(!press("a", keyCode: 0))  // other keys pass through
        #expect(!press(" ", keyCode: 49, flags: .command))
    }
}

struct DeinterlaceTests {
    /// Fills even rows (top field) with one gray and odd rows (bottom field) with another.
    static func paintFields(_ pixels: CVPixelBuffer, top: UInt8, bottom: UInt8) {
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<CVPixelBufferGetHeight(pixels) {
            memset(base + y * stride, Int32(y.isMultiple(of: 2) ? top : bottom), stride)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
    }

    static func meanBrightness(_ image: CGImage) -> Double {
        let width = 32, height = 32
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(bytes.reduce(0) { $0 + Int($1) }) / Double(bytes.count)
    }

    @Test func bobKeepsOneFieldAndFillsTheOther() throws {
        var source: CVPixelBuffer?, output: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 8, kCVPixelFormatType_32BGRA, nil, &source)
        CVPixelBufferCreate(nil, 64, 8, kCVPixelFormatType_32BGRA, nil, &output)
        let src = try #require(source), out = try #require(output)
        Self.paintFields(src, top: 200, bottom: 20)

        for (keepOdd, expected) in [(false, UInt8(200)), (true, UInt8(20))] {
            Deinterlacer.bob(src, into: out, keepOddRows: keepOdd)
            CVPixelBufferLockBaseAddress(out, .readOnly)
            let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(out)
            for y in 0..<8 { #expect(base[y * stride + 5] == expected) }
            CVPixelBufferUnlockBaseAddress(out, .readOnly)
        }
    }

    @Test func exportsInterlacedAsDoubleFrameRate() async throws {
        let dir = try TestVideo.tempDirectory()
        // Top field bright, bottom field dark: deinterlaced frames should alternate bright/dark.
        let url = try await TestVideo.make(in: dir, name: "interlaced", seconds: 1, size: CGSize(width: 720, height: 480),
                                           codec: .proRes422) { _, pixels in
            Self.paintFields(pixels, top: 230, bottom: 25)
        }
        let asset = AVURLAsset(url: url)
        let composition = try #require(try await Deinterlacer.videoComposition(for: asset, fieldOrder: .topFirst))
        #expect(composition.frameDuration == CMTime(value: 1, timescale: 60))

        let manager = ExportManager.test()
        let job = manager.export(asset: asset, videoComposition: composition, name: "out", preset: .builtIn("ProRes 422"), folder: dir)
        await job.task?.value
        #expect(job.state == .finished)

        let exported = AVURLAsset(url: job.outputURL)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        let fps = try await track.load(.nominalFrameRate)
        #expect(abs(fps - 60) < 1)

        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: CMTime(value: 10, timescale: 60)).image
        let second = try await generator.image(at: CMTime(value: 11, timescale: 60)).image
        #expect(Self.meanBrightness(first) > 180)  // top field
        #expect(Self.meanBrightness(second) < 70)  // bottom field
    }

    @Test func sdClipsOfferDeinterlacing() {
        let clip = Clip(url: URL(fileURLWithPath: "/tmp/tape.mov"))
        clip.displaySize = CGSize(width: 720, height: 480)
        clip.frameRate = 29.97
        #expect(clip.canDeinterlace)
        #expect(clip.outputFrameRate == 29.97)
        clip.deinterlace = true
        #expect(abs(clip.outputFrameRate - 59.94) < 0.01)
        #expect(clip.deinterlacedRateLabel == "60p")

        clip.displaySize = CGSize(width: 1920, height: 1080)
        #expect(!clip.canDeinterlace)  // HD only when the file says it's interlaced
        clip.isInterlaced = true
        #expect(clip.canDeinterlace)
    }
}

struct InspectorAndSpeedTests {
    @Test func readsFormatDetails() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 1, size: CGSize(width: 640, height: 360), codec: .proRes422)
        let clip = Clip(url: url)
        await MediaLoader.load(clip)

        #expect(clip.videoCodec == "Apple ProRes 422")
        #expect(clip.encodedSize == CGSize(width: 640, height: 360))
        #expect(clip.containerName != nil)
        #expect(MediaLoader.codecName(0x61766331) == "H.264")  // 'avc1'
        #expect(MediaLoader.codecName(0x64766320) == "DV (NTSC)")  // 'dvc '
    }

    @Test func playbackSpeedIsSeparateFromFrameRate() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 2, size: CGSize(width: 320, height: 240))
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)

        controller.playbackSpeed = 0.5
        controller.play()
        #expect(controller.player.rate == 0.5)
        #expect(controller.clock.fps == 30)  // frame rate unchanged
        controller.playbackSpeed = 2
        #expect(controller.player.rate == 2)
        controller.pause()
    }
}

/// Shows the full window with a clip selected, like dropping a movie in.
/// Layout feedback loops crash here with "more Update Constraints in Window passes than there are views".
struct WindowLayoutTests {
    @Test(arguments: [false, true])
    func clipWindowSettlesWithoutLayoutLoop(interlacedSD: Bool) async throws {
        let dir = try TestVideo.tempDirectory()
        let size = interlacedSD ? CGSize(width: 720, height: 480) : CGSize(width: 640, height: 360)
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 2, size: size)
        let store = ProjectStore(exporter: ExportManager.test())

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(store).environment(store.exporter))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        store.importAndSelect([url])
        // Let loading, thumbnails, and playback-time updates run through several display cycles.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(store.selectedClips.first?.isLoaded == true)
    }

    @Test func timelineWindowSettlesWithoutLayoutLoop() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "clip", seconds: 2, size: CGSize(width: 640, height: 360))
        let store = ProjectStore(exporter: ExportManager.test())

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(store).environment(store.exporter))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        store.addToTimeline(store.importFiles([url]))
        store.selection = [.timeline]
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(store.timeline.count == 1)
    }
}

/// SD captures (like DV from Hi8/VHS) store 720×480 pixels meant to be shown at 640×480.
struct PictureShapeTests {
    /// Hi8 capture files say "640 wide" twice: a 10:11 pixel aspect tag and a 0.889 scale.
    static let squeeze = CGAffineTransform(scaleX: 640.0 / 720.0, y: 1)

    @Test(arguments: [
        (true, false),  // pixel aspect tag only
        (false, true),  // transform scale only
        (true, true),   // both, like the Hi8 captures (used to come out 582 wide)
    ])
    func sdCaptureShowsAt640x480(tagged: Bool, scaled: Bool) async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(
            in: dir, name: "sd", seconds: 1, size: CGSize(width: 720, height: 480), codec: .proRes422,
            pixelAspect: tagged ? (10, 11) : nil, cleanApertureWidth: tagged ? 704 : nil,
            transform: scaled ? Self.squeeze : .identity
        )

        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(clip.encodedSize == CGSize(width: 720, height: 480))
        #expect(clip.displaySize == CGSize(width: 640, height: 480))

        let timeline = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1)])
        #expect(timeline.videoComposition?.renderSize == CGSize(width: 640, height: 480))

        let deinterlaced = try await Deinterlacer.videoComposition(for: AVURLAsset(url: url), fieldOrder: .bottomFirst)
        #expect(deinterlaced?.renderSize == CGSize(width: 640, height: 480))
    }

    @Test func squeezedClipFillsTimelineFrame() {
        // A 720-wide squeezed clip in a 640×480 timeline fills it exactly: no crop, no bars.
        let t = CompositionBuilder.fitTransform(
            natural: CGSize(width: 720, height: 480), preferred: Self.squeeze, into: CGSize(width: 640, height: 480)
        )
        let rect = CGRect(x: 0, y: 0, width: 720, height: 480).applying(t)
        #expect(abs(rect.minX) < 0.01 && abs(rect.width - 640) < 0.01 && abs(rect.height - 480) < 0.01)
    }

    @Test func rotatedPhoneVideoIsUnchanged() {
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geometry = VideoGeometry(format: nil, naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: rotate)
        #expect(geometry.displaySize == CGSize(width: 1080, height: 1920))
    }
}

struct EnhanceTests {
    /// Gray picture with fresh random noise every frame, like tape noise.
    static func noisyClip(in dir: URL, seconds: Int = 2) async throws -> URL {
        try await TestVideo.make(
            in: dir, name: "noisy", seconds: seconds, size: CGSize(width: 720, height: 480), codec: .proRes422,
            transform: PictureShapeTests.squeeze
        ) { frame, pixels in
            var rng = SystemRandomNumberGenerator()
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<CVPixelBufferGetHeight(pixels) {
                for x in 0..<CVPixelBufferGetWidth(pixels) {
                    let value = UInt8(clamping: 128 + Int.random(in: -40...40, using: &rng))
                    let p = base + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    /// Mean and standard deviation of brightness in the middle of a frame.
    static func stats(_ url: URL, at seconds: Double) async throws -> (mean: Double, deviation: Double, size: CGSize) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let size = CGSize(width: image.width, height: image.height)
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // Sample a 1:1 crop from the center so noise isn't averaged away by scaling.
        let crop = image.cropping(to: CGRect(x: image.width / 2 - side / 2, y: image.height / 2 - side / 2, width: side, height: side))!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        let values = bytes.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return (mean, variance.squareRoot(), size)
    }

    static func export(_ url: URL, _ settings: EnhanceSettings, to dir: URL, name: String) async throws -> ExportJob {
        let playable = try await Enhancer.makePlayable(url: url, settings: settings)
        let manager = ExportManager.test()
        let job = manager.export(asset: playable.asset, videoComposition: playable.videoComposition,
                                 name: name, preset: .builtIn("ProRes 422"), folder: dir)
        await job.task?.value
        return job
    }

    @Test func reduceNoiseLowersNoiseAndKeepsBrightness() async throws {
        #expect(Enhancer.canReduceNoise)
        let dir = try TestVideo.tempDirectory()
        let source = try await Self.noisyClip(in: dir)
        let started = Date()
        let job = try await Self.export(source, EnhanceSettings(denoiseStrength: 1), to: dir, name: "denoised")
        let elapsed = Date().timeIntervalSince(started)
        #expect(job.state == .finished, "\(job.state)")

        let before = try await Self.stats(source, at: 1)
        let after = try await Self.stats(job.outputURL, at: 1)
        print("Denoise: noise \(before.deviation) → \(after.deviation), brightness \(before.mean) → \(after.mean), size \(after.size), \(elapsed)s for 60 frames")
        #expect(after.size == CGSize(width: 640, height: 480))
        #expect(after.deviation < before.deviation * 0.8)
        #expect(abs(after.mean - before.mean) < 6)
        let duration = try await AVURLAsset(url: job.outputURL).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test func allEffectsTogetherDoubleSizeAndFrameRate() async throws {
        let display = CGSize(width: 640, height: 480)
        try #require(Enhancer.canUpscale(.fast, displaySize: display))
        let dir = try TestVideo.tempDirectory()
        let source = try await Self.noisyClip(in: dir, seconds: 1)
        let settings = EnhanceSettings(fieldOrder: .bottomFirst, denoiseStrength: 0.6, upscale: .fast, sharpen: 0.3)
        let started = Date()
        let job = try await Self.export(source, settings, to: dir, name: "all")
        let elapsed = Date().timeIntervalSince(started)
        #expect(job.state == .finished, "\(job.state)")

        let after = try await Self.stats(job.outputURL, at: 0.5)
        print("All effects: size \(after.size), brightness \(after.mean), \(elapsed)s for 60 output frames")
        #expect(after.size == CGSize(width: 1280, height: 960))
        let track = try #require(try await AVURLAsset(url: job.outputURL).loadTracks(withMediaType: .video).first)
        #expect(abs(try await track.load(.nominalFrameRate) - 60) < 1)
        let before = try await Self.stats(source, at: 0.5)
        #expect(abs(after.mean - before.mean) < 8)
    }

    @Test(arguments: [
        ("deinterlace", EnhanceSettings(fieldOrder: .bottomFirst)),
        ("upscale 2x", EnhanceSettings(upscale: .fast)),
        ("sharpen", EnhanceSettings(sharpen: 0.3)),
    ])
    func stageSpeed(name: String, settings: EnhanceSettings) async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await Self.noisyClip(in: dir, seconds: 1)
        let started = Date()
        let job = try await Self.export(source, settings, to: dir, name: "stage")
        print("Stage \(name): \(Date().timeIntervalSince(started))s, \(job.state)")
        #expect(job.state == .finished)
    }

    @Test func bestNeedsModelOrWorks() async throws {
        // The 4× model is a one-time download; without it the export explains what to do.
        let dir = try TestVideo.tempDirectory()
        let source = try await Self.noisyClip(in: dir, seconds: 1)
        let ready = Enhancer.bestScalerConfiguration(width: 640, height: 480)?.configurationModelStatus == .ready
        let job = try await Self.export(source, EnhanceSettings(upscale: .best), to: dir, name: "best")
        if ready {
            #expect(job.state == .finished)
            #expect(try await Self.stats(job.outputURL, at: 0.5).size == CGSize(width: 2560, height: 1920))
        } else {
            guard case .failed = job.state else { Issue.record("Expected a clear failure without the model"); return }
        }
    }
}

struct BobSpeedTests {
    @Test func bobSpeed() throws {
        var source: CVPixelBuffer?, output: CVPixelBuffer?
        CVPixelBufferCreate(nil, 720, 480, kCVPixelFormatType_32BGRA, nil, &source)
        CVPixelBufferCreate(nil, 720, 480, kCVPixelFormatType_32BGRA, nil, &output)
        let started = Date()
        for i in 0..<60 { Deinterlacer.bob(source!, into: output!, keepOddRows: i.isMultiple(of: 2)) }
        print("Bob: \(Date().timeIntervalSince(started) / 60 * 1000) ms per field")
    }
}

struct EffectsPreviewTests {
    @Test func previewRebuildsWithEffects() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await EnhanceTests.noisyClip(in: dir, seconds: 1)
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(clip.canEnhance)

        let controller = ClipPlayerController()
        controller.load(clip)
        clip.denoise = true
        clip.upscale = .fast
        clip.sharpen = 0.2
        await controller.applyEffects()
        #expect(clip.effectsError == nil)
        #expect(controller.player.currentItem?.videoComposition?.renderSize == CGSize(width: 1280, height: 960))
        #expect(clip.outputSize == CGSize(width: 1280, height: 960))
        #expect(clip.exportNameSuffix == "Enhanced")

        clip.denoise = false
        clip.upscale = .off
        clip.sharpen = 0
        await controller.applyEffects()
        #expect(controller.player.currentItem?.videoComposition == nil)
    }

    @Test func windowWithAllEffectsSettles() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await EnhanceTests.noisyClip(in: dir, seconds: 2)
        let store = ProjectStore(exporter: ExportManager.test())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(store).environment(store.exporter))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        store.importAndSelect([url])
        let clip = try #require(store.selectedClips.first)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            window.displayIfNeeded()
        }
        clip.deinterlace = true
        clip.denoise = true
        clip.upscale = .fast
        clip.sharpen = 0.3
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            window.displayIfNeeded()
        }
        #expect(clip.effectsError == nil)
    }
}

struct EffectsSetTests {
    @Test func saveLoadResetAndPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "FunSizeTests.presets.\(UUID().uuidString)"))
        let store = EffectsPresetStore(defaults: defaults)
        let clip = Clip(url: URL(fileURLWithPath: "/tmp/a.mov"))
        clip.denoise = true
        clip.denoiseStrength = 0.7
        clip.upscale = .fast
        clip.sharpen = 0.2
        store.save(name: "VHS Cleanup", from: clip)

        clip.resetEffects()
        #expect(!clip.denoise && clip.upscale == .off && clip.sharpen == 0)
        #expect(clip.deinterlace == false)

        let preset = try #require(store.presets.first)
        preset.apply(to: clip)
        #expect(clip.denoise && clip.denoiseStrength == 0.7 && clip.upscale == .fast && clip.sharpen == 0.2)
        #expect(preset.matches(clip))

        // Same name replaces; sets survive a relaunch.
        clip.sharpen = 0.5
        store.save(name: "vhs cleanup", from: clip)
        #expect(store.presets.count == 1)
        let reloaded = EffectsPresetStore(defaults: defaults)
        #expect(reloaded.presets.first?.sharpen == 0.5)

        reloaded.delete(try #require(reloaded.presets.first))
        #expect(EffectsPresetStore(defaults: defaults).presets.isEmpty)
    }

    @Test func showOriginalSwapsAndKeepsPosition() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await EnhanceTests.noisyClip(in: dir, seconds: 2)
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        clip.deinterlace = true
        clip.denoise = true
        clip.upscale = .fast
        await controller.applyEffects()
        controller.seek(to: 1)

        let effectsSize = controller.player.currentItem?.videoComposition?.renderSize
        #expect(effectsSize == CGSize(width: 1280, height: 960))

        controller.showOriginal(true)
        #expect(controller.isShowingOriginal)
        // Original keeps Timing (deinterlaced 60p) but drops Effects.
        let original = try #require(controller.player.currentItem?.videoComposition)
        #expect(original.renderSize == CGSize(width: 640, height: 480))
        #expect(original.frameDuration == CMTime(value: 1, timescale: 60))
        #expect(abs(controller.currentTime - 1) < 0.02)

        controller.showOriginal(false)
        #expect(controller.player.currentItem?.videoComposition?.renderSize == effectsSize)
        #expect(abs(controller.currentTime - 1) < 0.02)
    }
}

struct NoFlashTests {
    @Test func switchingShowsAStillFrameUntilReady() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await EnhanceTests.noisyClip(in: dir, seconds: 2)
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        clip.denoise = true
        clip.upscale = .fast
        await controller.applyEffects()
        controller.seek(to: 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.freezeFrame == nil)

        // Press: a still frame covers the swap, then goes away once the original is ready.
        controller.showOriginal(true)
        #expect(controller.freezeFrame != nil)
        try await Task.sleep(for: .milliseconds(800))
        #expect(controller.freezeFrame == nil)

        // Release: the stored effects frame for this moment is shown right away.
        controller.showOriginal(false)
        let frame = try #require(controller.freezeFrame)
        #expect(frame.width == 1280)  // the enhanced frame, not the original
        try await Task.sleep(for: .milliseconds(800))
        #expect(controller.freezeFrame == nil)
    }
}

struct CaptionTests {
    @Test func clipsWithoutCaptionsHideTheSwitch() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "silent", seconds: 1, size: CGSize(width: 320, height: 240))
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(!clip.hasCaptions)
        #expect(!clip.showCaptions)  // off by default

        let controller = ClipPlayerController()
        #expect(!controller.player.appliesMediaSelectionCriteriaAutomatically)
        controller.load(clip)
        clip.showCaptions = true
        await controller.updateCaptions()  // no captions: nothing to change, no crash
    }
}

struct ProjectFileTests {
    @Test func savesAndReopensClipsSettingsAndTimeline() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "saved", seconds: 2, size: CGSize(width: 320, height: 240))

        let store = ProjectStore(exporter: ExportManager.test())
        let clip = try #require(store.importFiles([url]).first)
        clip.inPoint = 0.5
        clip.outPoint = 1.5
        clip.denoise = true
        clip.denoiseStrength = 0.8
        clip.upscale = .fast
        clip.sharpen = 0.3
        clip.deinterlace = true
        clip.fieldOrderChoice = .topFirst
        clip.showCaptions = true
        store.addToTimeline([clip])

        // Through the same encoding the document uses.
        var document = ProjectDocument(file: store.projectFile)
        let data = try JSONEncoder().encode(document.file)
        document.file = try JSONDecoder().decode(ProjectFile.self, from: data)

        let reopened = ProjectStore(exporter: ExportManager.test())
        reopened.apply(document.file)
        reopened.selectInitialItem()
        #expect(reopened.projectFile == store.projectFile)
        #expect(reopened.selection == [.timeline])

        let copy = try #require(reopened.clips.first)
        #expect(copy.id == clip.id)
        #expect(copy.url.standardizedFileURL == url.standardizedFileURL)
        #expect(copy.markedRange == 0.5...1.5)
        #expect(copy.denoise && copy.denoiseStrength == 0.8 && copy.sharpen == 0.3)
        #expect(copy.fieldOrderChoice == .topFirst && copy.showCaptions && copy.upscale == .fast)
        #expect(reopened.timeline.first?.trimStart == 0.5)

        // The video loads again from the saved project.
        for _ in 0..<100 where !copy.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(copy.isLoaded)
    }

    @Test func undoStyleChangesUpdateExistingClips() async throws {
        let dir = try TestVideo.tempDirectory()
        let a = try await TestVideo.make(in: dir, name: "a", seconds: 1, size: CGSize(width: 320, height: 240))
        let b = try await TestVideo.make(in: dir, name: "b", seconds: 1, size: CGSize(width: 320, height: 240))
        let store = ProjectStore(exporter: ExportManager.test())
        let before = store.projectFile
        store.importFiles([a])
        let oneClip = store.projectFile
        let first = store.clips[0]
        store.importFiles([b])
        first.sharpen = 0.5

        store.apply(oneClip)  // like Undo
        #expect(store.clips.count == 1)
        #expect(store.clips[0] === first)  // same clip object, nothing reloaded
        #expect(first.sharpen == 0)

        store.apply(before)
        #expect(store.clips.isEmpty)
    }

    @Test func openVideoStartsProjectWithThatClipSelected() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "tape", seconds: 1, size: CGSize(width: 320, height: 240))
        let notVideo = dir.appending(path: "notes.txt")
        try Data("hi".utf8).write(to: notVideo)

        let file = ProjectFile.with(videos: [url, notVideo])
        #expect(file.clips.count == 1)

        let store = ProjectStore(exporter: ExportManager.test())
        store.apply(file)
        store.selectInitialItem()
        #expect(store.selectedClips.first?.name == "tape")
    }

    @Test func olderFilesWithMissingFieldsStillOpen() throws {
        let json = #"{"version":1,"clips":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/nowhere/tape.mov"}],"timeline":[]}"#
        let file = try JSONDecoder().decode(ProjectFile.self, from: Data(json.utf8))
        #expect(file.clips.first?.denoiseStrength == 0.5)
        #expect(file.clips.first?.upscale == .off)
    }

    @Test func missingVideoSaysSo() async throws {
        var file = ProjectFile()
        file.clips = [.init(url: URL(filePath: "/nowhere/tape.mov"), bookmark: nil)]
        let store = ProjectStore(exporter: ExportManager.test())
        store.apply(file)
        let clip = try #require(store.clips.first)
        for _ in 0..<50 where clip.loadError == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(clip.loadError?.contains("Can't find") == true)
    }

    @Test func welcomeWindowLaysOut() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WelcomeView())
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(window.contentView?.fittingSize.width ?? 0 >= 700)
    }
}

/// A 440 Hz stereo tone for test videos, written as AAC.
final class TestAudio {
    static let rate = 48_000
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: TestAudio.rate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ])
    private var format: CMAudioFormatDescription?

    init() {
        input.expectsMediaDataInRealTime = false
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }

    /// The sound that goes with one video frame.
    func appendChunk(frame: Int, fps: Int) throws {
        let start = frame * Self.rate / fps
        let count = (frame + 1) * Self.rate / fps - start
        var samples = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            let value = Int16(sin(Double(start + i) * 2 * .pi * 440 / Double(Self.rate)) * 8000)
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        let length = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try #require(block)
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: length)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try #require(format), sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Self.rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        input.append(try #require(buffer))
    }
}

extension ExportManager {
    /// An export manager with its own settings, so tests don't change the app's.
    static func test(_ name: String = "FunSizeTests") -> ExportManager {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ExportManager(defaults: defaults)
    }
}

extension ExportPreset {
    static func builtIn(_ name: String) -> ExportPreset {
        defaults.first { $0.name == name }!
    }
}
