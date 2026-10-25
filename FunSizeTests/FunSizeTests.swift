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

struct ExportTests {
    @Test(arguments: [ExportFormat.mp4, .hevc, .hd720, .proRes])
    func exportsSingleClip(format: ExportFormat) async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "src", seconds: 1, size: CGSize(width: 640, height: 360))
        let manager = ExportManager()

        let job = try #require(manager.export(asset: AVURLAsset(url: source), name: "src", format: format, folder: dir))
        await job.task?.value

        #expect(job.state == .finished)
        #expect(job.outputURL.pathExtension == format.fileExtension)
        #expect(FileManager.default.fileExists(atPath: job.outputURL.path(percentEncoded: false)))
    }

    @Test func exportsCombinedTimeline() async throws {
        let dir = try TestVideo.tempDirectory()
        let a = try await TestVideo.make(in: dir, name: "a", seconds: 1, size: CGSize(width: 640, height: 360))
        let b = try await TestVideo.make(in: dir, name: "b", seconds: 1, size: CGSize(width: 360, height: 640))
        let built = try await CompositionBuilder.build([.init(url: a, start: 0, end: 1), .init(url: b, start: 0, end: 1)])

        let manager = ExportManager()
        let job = try #require(manager.export(
            asset: built.composition, videoComposition: built.videoComposition,
            name: "timeline", format: .mp4, folder: dir
        ))
        await job.task?.value

        #expect(job.state == .finished)
        let duration = try await AVURLAsset(url: job.outputURL).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }
}

struct StoreTests {
    @Test func reorderAndTrim() {
        let store = ProjectStore(exporter: ExportManager())
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
    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func make(
        in dir: URL, name: String, seconds: Int, size: CGSize, fps: Int32 = 30,
        codec: AVVideoCodecType = .h264,
        pixelAspect: (Int, Int)? = nil,
        cleanApertureWidth: Int? = nil,
        transform: CGAffineTransform = .identity,
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(Int(fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
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
        }
        input.markAsFinished()
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
        let store = ProjectStore(exporter: ExportManager())
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
        let store = ProjectStore(exporter: ExportManager())
        let clip = try #require(store.importFiles([url]).first)
        await MediaLoader.load(clip)
        clip.inPoint = 1
        clip.outPoint = 2

        store.addToTimeline([clip])
        #expect(store.timelineDuration == 1)

        let job = try #require(store.exporter.export(
            asset: AVURLAsset(url: url),
            timeRange: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 2, preferredTimescale: 600)),
            name: "clip", format: .mp4, folder: dir
        ))
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

        let manager = ExportManager()
        let job = try #require(manager.export(asset: asset, videoComposition: composition, name: "out", format: .proRes, folder: dir))
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
        let store = ProjectStore(exporter: ExportManager())

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
        let store = ProjectStore(exporter: ExportManager())

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
