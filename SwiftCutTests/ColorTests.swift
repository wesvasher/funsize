import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import SwiftCut

struct CubeFileTests {
    @Test func roundTripsAndReadsTitleAndComments() throws {
        let lut = ColorLUT.builtIns.first { $0.name == "Warm" }!
        let text = CubeFile.write(lut)
        let read = try CubeFile.read("# A comment\n\n" + text)
        #expect(read.title == "Warm")
        #expect(read.size == lut.size)
        let copy = ColorLUT(id: UUID(), name: "", kind: .imported, summary: "", size: read.size, data: read.data)
        for probe in [SIMD3(0.1, 0.5, 0.9), SIMD3(0.7, 0.2, 0.4)] {
            #expect(simd_length(copy.apply(probe) - lut.apply(probe)) < 0.001)
        }
    }

    @Test func readsOneDimensionalAndCustomDomain() throws {
        // 1D: invert every channel.
        let oneD = "LUT_1D_SIZE 2\n1.0 1.0 1.0\n0.0 0.0 0.0\n"
        let inverted = try CubeFile.read(oneD)
        let lut = ColorLUT(id: UUID(), name: "", kind: .imported, summary: "", size: inverted.size, data: inverted.data)
        #expect(simd_length(lut.apply(SIMD3(0.25, 0.5, 1)) - SIMD3(0.75, 0.5, 0)) < 0.01)

        // A 2-point identity cube over 0…2: input 0.5 sits a quarter of the way along.
        var lines = ["LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 2 2 2"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(r * 2) \(g * 2) \(b * 2)") } } }
        let domain = try CubeFile.read(lines.joined(separator: "\n"))
        let scaled = ColorLUT(id: UUID(), name: "", kind: .imported, summary: "", size: domain.size, data: domain.data)
        #expect(abs(scaled.apply(SIMD3(0.5, 0.5, 0.5)).x - 0.5) < 0.02)
    }

    @Test func rejectsBadFiles() {
        #expect(throws: (any Error).self) { try CubeFile.read("hello") }
        #expect(throws: (any Error).self) { try CubeFile.read("LUT_3D_SIZE 2\n0 0 0\n") }
    }
}

struct AppleLogTests {
    @Test func middleGrayComesOutNeutralAtVideoLevel() {
        let gray = ColorMath.linearToAppleLog(0.18)
        #expect(abs(gray - 0.488) < 0.005)
        #expect(abs(ColorMath.appleLogToLinear(gray) - 0.18) < 0.0001)

        let lut = ColorLUT.builtIns[0]
        #expect(lut.kind == .appleLog)
        let out = lut.apply(SIMD3(repeating: gray))
        #expect(abs(out.x - out.y) < 0.01 && abs(out.y - out.z) < 0.01)
        #expect(out.y > 0.38 && out.y < 0.5)
        // Brighter scene light stays brighter (no clipping of the range).
        #expect(lut.apply(SIMD3(repeating: ColorMath.linearToAppleLog(1.0))).y > out.y + 0.2)
    }

    @Test func builtInsAreUniqueAndBlackAndWhiteRemovesColor() {
        #expect(Set(ColorLUT.builtIns.map(\.id)).count == ColorLUT.builtIns.count)
        let bw = ColorLUT.builtIns.first { $0.name == "Black & White" }!
        let red = bw.apply(SIMD3(0.9, 0.1, 0.1))
        #expect(abs(red.x - red.z) < 0.01)
    }
}

@Suite(.serialized)
struct LUTLibraryTests {
    @Test func importsAndDeletes() throws {
        let dir = try TestVideo.tempDirectory()
        let library = LUTLibrary(directory: dir.appending(path: "LUTs"))
        #expect(library.imported.isEmpty)

        let file = dir.appending(path: "My Look.cube")
        let source = ColorLUT.builtIns.first { $0.name == "Cool" }!
        try CubeFile.write(source).replacingOccurrences(of: "TITLE \"Cool\"\n", with: "").write(to: file, atomically: true, encoding: .utf8)
        let lut = try library.importFile(file)
        #expect(lut.name == "My Look")  // no TITLE: named after the file
        #expect(library.imported.map(\.id) == [lut.id])

        // Reopening finds it again.
        #expect(LUTLibrary(directory: library.directory).lut(id: lut.id)?.name == "My Look")

        library.delete([lut.id, ColorLUT.builtIns[0].id])  // built-ins can't be deleted
        #expect(library.imported.isEmpty)
        #expect(library.lut(id: ColorLUT.builtIns[0].id) != nil)
    }
}

struct LUTPipelineTests {
    /// Exports a red clip through the effects pipeline and reads back the center color.
    private func exportedColor(_ settings: EnhanceSettings) async throws -> SIMD3<Double> {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 320, height: 240)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255  // BGRA red
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let playable = try await Enhancer.makePlayable(url: url, settings: settings)
        let job = ExportManager.test().export(asset: playable.asset, videoComposition: playable.videoComposition,
                                              name: "graded", preset: .builtIn("ProRes 422"), folder: dir)
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: job.outputURL))
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
    }

    @Test func lutChangesExportedColorAndIntensityBlends() async throws {
        let bw = ColorLUT.builtIns.first { $0.name == "Black & White" }!
        let full = try await exportedColor(EnhanceSettings(lut: AppliedLUT(lut: bw, intensity: 1)))
        #expect(abs(full.x - full.z) < 0.05, "black and white: \(full)")

        let half = try await exportedColor(EnhanceSettings(lut: AppliedLUT(lut: bw, intensity: 0.5)))
        #expect(half.x - half.z > 0.15, "half strength keeps some red: \(half)")
        #expect(half.x - half.z < 0.6)
    }
}

struct ColorProjectTests {
    @Test func lutChoiceIsSavedInProjects() throws {
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = Clip(url: URL(filePath: "/tmp/x.mov"))
        clip.displaySize = CGSize(width: 640, height: 480)
        clip.lutID = ColorLUT.builtIns[2].id
        clip.lutIntensity = 0.4
        store.clips = [clip]
        let data = try JSONEncoder().encode(store.projectFile)
        let record = try #require(try JSONDecoder().decode(ProjectFile.self, from: data).clips.first)
        #expect(record.lutID == clip.lutID && record.lutIntensity == 0.4)
        #expect(clip.exportNameSuffix.contains("Graded"))
    }
}
