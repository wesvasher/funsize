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

    static func make(in dir: URL, name: String, seconds: Int, size: CGSize, fps: Int32 = 30) async throws -> URL {
        let url = dir.appending(path: "\(name).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
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
            CVPixelBufferLockBaseAddress(pixels, [])
            let shade = UInt8(frame * 4 % 255)
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
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
