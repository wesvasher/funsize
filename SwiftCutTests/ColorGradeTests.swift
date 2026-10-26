import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

struct ColorGradeTests {
    private let gray = SIMD3<Double>(repeating: 0.5)

    @Test func untouchedGradeChangesNothing() {
        let grade = ColorGrade()
        #expect(grade.isIdentity)
        for v in [SIMD3<Double>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.2, 0.6, 0.9)] {
            #expect(simd_distance(grade.apply(v), v) < 1e-9)
        }
    }

    @Test func exposureBrightensAndDarkensInStops() {
        let up = ColorGrade(exposure: 1).apply(gray)
        let down = ColorGrade(exposure: -1).apply(gray)
        #expect(up.x > 0.6 && down.x < 0.4)
        // One stop doubles the light.
        #expect(abs(ColorMath.decodeDisplay(up.x) / ColorMath.decodeDisplay(0.5) - 2) < 0.01)
    }

    @Test func contrastPivotsAroundTheMiddle() {
        let more = ColorGrade(contrast: 0.5), less = ColorGrade(contrast: -0.5)
        #expect(abs(more.apply(gray).x - 0.5) < 1e-9)
        #expect(more.apply(SIMD3(repeating: 0.25)).x < 0.25 && more.apply(SIMD3(repeating: 0.75)).x > 0.75)
        #expect(less.apply(SIMD3(repeating: 0.25)).x > 0.25 && less.apply(SIMD3(repeating: 0.75)).x < 0.75)
        #expect(more.apply(.zero) == .zero && more.apply(.one) == .one)
    }

    @Test func highlightsAndShadowsMostlyMoveTheirOwnTones() {
        let dark = SIMD3<Double>(repeating: 0.2), bright = SIMD3<Double>(repeating: 0.9)
        let recover = ColorGrade(highlights: -1)
        #expect(bright.x - recover.apply(bright).x > 0.1)
        #expect(abs(recover.apply(dark).x - dark.x) < 0.01)

        let lift = ColorGrade(shadows: 1)
        #expect(lift.apply(dark).x - dark.x > 0.1)
        #expect(lift.apply(bright).x - bright.x < 0.03)
        // Pure black stays black, so lifting shadows doesn't turn it gray.
        #expect(lift.apply(.zero).x < 0.01)
    }

    @Test func saturationAndVibrance() {
        let red = SIMD3<Double>(0.8, 0.2, 0.2), muted = SIMD3<Double>(0.55, 0.45, 0.45)
        let bw = ColorGrade(saturation: -1).apply(red)
        #expect(abs(bw.x - bw.z) < 1e-6)

        let vibrant = ColorGrade(vibrance: 1)
        let mutedGain = (vibrant.apply(muted).x - vibrant.apply(muted).z) / (muted.x - muted.z)
        let strongGain = (vibrant.apply(red).x - vibrant.apply(red).z) / (red.x - red.z)
        #expect(mutedGain > strongGain && mutedGain > 1.5)
    }

    @Test func temperatureAndTintShiftColor() {
        let warm = ColorGrade(temperature: 1).apply(gray), cool = ColorGrade(temperature: -1).apply(gray)
        #expect(warm.x > warm.z && cool.z > cool.x)
        let magenta = ColorGrade(tint: 1).apply(gray)
        #expect(magenta.y < magenta.x && magenta.y < magenta.z)
    }

    @Test func savedGradeReadsMissingControlsAsUntouched() throws {
        let grade = ColorGrade(exposure: 0.5, vibrance: -0.25)
        let copy = try JSONDecoder().decode(ColorGrade.self, from: JSONEncoder().encode(grade))
        #expect(copy == grade)
        // A grade saved before some controls existed.
        let old = try JSONDecoder().decode(ColorGrade.self, from: Data(#"{"exposure": 1}"#.utf8))
        #expect(old == ColorGrade(exposure: 1))
    }

    @Test func liveColorMakesOneCubePerChange() {
        let live = LiveColor()
        #expect(live.snapshot().gradeLUT == nil)
        live.value.grade = ColorGrade(saturation: -1)
        let first = live.snapshot().gradeLUT
        #expect(first != nil && live.snapshot().gradeLUT === first)
        // Changing the LUT alone keeps the grade's cube.
        live.value.lut = AppliedLUT(lut: ColorLUT.builtIns[3], intensity: 0.5)
        #expect(live.snapshot().gradeLUT === first)
        live.value.grade.saturation = -0.5
        #expect(live.snapshot().gradeLUT !== first)
    }

    @Test func gradeValuesDontRebuildThePreview() {
        let clip = Clip(url: URL(filePath: "/tmp/x.mov"))
        clip.displaySize = CGSize(width: 640, height: 480)
        #expect(clip.enhanceSettings.grade == nil && !clip.enhanceSettings.hasLook)
        clip.grade.exposure = 0.5
        let a = clip.enhanceSettings
        clip.grade.contrast = 0.3
        let b = clip.enhanceSettings
        #expect(a != b && a.structure == b.structure && a.hasLook)
        // Choosing a LUT or changing its intensity doesn't rebuild either.
        clip.lutID = ColorLUT.builtIns[3].id
        let c = clip.enhanceSettings
        clip.lutIntensity = 0.4
        #expect(c != clip.enhanceSettings && c.structure == b.structure && clip.enhanceSettings.structure == b.structure)
        #expect(clip.exportNameSuffix.contains("Graded"))
        // Show Original drops the grade.
        #expect(b.timingOnly.grade == nil)
    }

    @Test func gradeIsSavedInProjectsAndOldProjectsOpen() throws {
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = Clip(url: URL(filePath: "/tmp/x.mov"))
        clip.grade = ColorGrade(exposure: -0.5, temperature: 0.3)
        store.clips = [clip]
        let file = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(store.projectFile))
        #expect(file.clips.first?.grade == clip.grade)

        let old = #"{"clips": [{"id": "\#(UUID())", "path": "/tmp/y.mov"}]}"#
        let oldFile = try JSONDecoder().decode(ProjectFile.self, from: Data(old.utf8))
        #expect(oldFile.clips.first?.grade.isIdentity == true)
    }

    @Test func savingAGradeAddsItToTheLibrary() throws {
        let library = LUTLibrary.shared
        let lut = ColorGrade(saturation: -1).makeLUT(name: "Test Grade \(UUID())")
        try library.add(lut)
        defer { library.delete([lut.id]) }
        let saved = try #require(library.lut(id: lut.id))
        #expect(saved.name == lut.name && saved.kind == .imported)
        let out = saved.apply(SIMD3(0.8, 0.2, 0.2))
        #expect(abs(out.x - out.z) < 0.02)
    }
}

struct GradePipelineTests {
    /// A red clip's center color, through the pipeline, at 0.5 s.
    private func renderedColor(_ asset: AVAsset, _ composition: AVVideoComposition?) async throws -> SIMD3<Double> {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
    }

    private func redClip() async throws -> URL {
        let dir = try TestVideo.tempDirectory()
        return try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 320, height: 240)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255  // BGRA red
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    @Test func liveGradeChangesFramesWithoutRebuilding() async throws {
        let url = try await redClip()
        let start = ColorLook(grade: ColorGrade(exposure: 0.0001))
        let live = LiveColor(start)
        let playable = try await Enhancer.makePlayable(url: url, settings: EnhanceSettings(grade: start.grade), liveColor: live)
        let before = try await renderedColor(playable.asset, playable.videoComposition)
        #expect(before.x - before.z > 0.4, "starts red: \(before)")

        // Same asset and composition: only the live value changes.
        live.value.grade = ColorGrade(saturation: -1)
        let after = try await renderedColor(playable.asset, playable.videoComposition)
        #expect(abs(after.x - after.z) < 0.05, "now black and white: \(after)")

        // A LUT chosen afterwards also shows without a rebuild.
        let warm = ColorLUT.builtIns.first { $0.name == "Warm" }!
        live.value = ColorLook(lut: AppliedLUT(lut: warm, intensity: 1))
        let warmed = try await renderedColor(playable.asset, playable.videoComposition)
        #expect(warmed.x - warmed.z > 0.4, "red again, through the Warm LUT: \(warmed)")
    }

    @Test func exportUsesTheGrade() async throws {
        let url = try await redClip()
        let playable = try await Enhancer.makePlayable(url: url, settings: EnhanceSettings(grade: ColorGrade(exposure: -1)))
        let dark = try await renderedColor(playable.asset, playable.videoComposition)
        let plain = try await renderedColor(AVURLAsset(url: url), nil)
        #expect(plain.x - dark.x > 0.1, "exposure −1 darkens: \(plain) → \(dark)")
    }
}

struct ResetAllTests {
    @Test func resetAllRestoresImportDefaultsButKeepsMarks() {
        let clip = Clip(url: URL(filePath: "/tmp/x.mov"))
        clip.displaySize = CGSize(width: 640, height: 480)
        #expect(clip.isAtDefaults)

        clip.deinterlace = true
        clip.fieldOrderChoice = .topFirst
        clip.showCaptions = true
        clip.denoise = true
        clip.upscale = .fast
        clip.sharpen = 0.4
        clip.lutID = ColorLUT.builtIns[4].id
        clip.lutIntensity = 0.3
        clip.grade.exposure = 1
        clip.inPoint = 1
        #expect(!clip.isAtDefaults)

        clip.resetAll()
        #expect(clip.isAtDefaults)
        #expect(clip.lutID == nil && clip.grade.isIdentity && !clip.enhanceSettings.isActive)
        #expect(clip.inPoint == 1)
    }

    @Test func appleLogFootageKeepsItsConversion() {
        let clip = Clip(url: URL(filePath: "/tmp/log.mov"))
        clip.displaySize = CGSize(width: 1920, height: 1080)
        clip.logFormat = "Apple Log"
        let conversion = clip.defaultLUTID
        #expect(conversion == ColorSettings.autoLUTForAppleLog)
        clip.lutID = nil
        #expect(!clip.isAtDefaults)
        clip.resetAll()
        #expect(clip.lutID == conversion && clip.isAtDefaults)
    }
}

struct ColorProxyTests {
    @Test func draggingShowsAQuickRecoloredFrameThenRemovesIt() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 1920, height: 1080)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        controller.currentTime = 0.5

        controller.beginColorAdjustment()
        clip.grade.saturation = -1
        controller.updateColor()
        for _ in 0..<200 where controller.colorProxy == nil { try await Task.sleep(for: .milliseconds(10)) }
        let proxy = try #require(controller.colorProxy)
        #expect(max(proxy.width, proxy.height) <= Int(ClipPlayerController.proxySize))

        // Wait for the newest settings to be drawn, then check the center is gray.
        try await Task.sleep(for: .milliseconds(200))
        let frame = try #require(controller.colorProxy)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(frame.cropping(to: CGRect(x: frame.width / 2, y: frame.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(Int(pixel[0]) - Int(pixel[2])) < 12, "black and white: \(pixel)")

        controller.endColorAdjustment()
        for _ in 0..<400 where controller.colorProxy != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.colorProxy == nil)
    }

    /// Choosing a LUT from the menu (no slider) shows it right away on the quick preview,
    /// even though the full preview has to be rebuilt to add color.
    @Test func choosingALUTShowsItRightAway() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "red", seconds: 1, size: CGSize(width: 1920, height: 1080)) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = 40; base[i + 1] = 40; base[i + 2] = 220; base[i + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        controller.currentTime = 0.5

        clip.lutID = ColorLUT.builtIns.first { $0.name == "Black & White" }!.id
        controller.updateColor()
        for _ in 0..<100 where controller.colorProxy == nil { try await Task.sleep(for: .milliseconds(10)) }
        let frame = try #require(controller.colorProxy, "a quick preview within a second")
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(frame.cropping(to: CGRect(x: frame.width / 2, y: frame.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(Int(pixel[0]) - Int(pixel[2])) < 12, "black and white: \(pixel)")

        // The full preview catches up (the view runs the rebuild), then the quick one goes away.
        await controller.applyEffects()
        for _ in 0..<400 where controller.colorProxy != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.colorProxy == nil)
    }
}
