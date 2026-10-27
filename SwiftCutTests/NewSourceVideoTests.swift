import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

struct NewSourceVideoTests {
    @Test func bakesOnlyTheChosenParts() {
        var grade = ColorGrade()
        grade.exposure = 1
        let all = EnhanceSettings(fieldOrder: .bottomFirst, denoiseStrength: 0.5, upscale: .off, sharpen: 0.4, grade: grade)
        var options = NewSourceOptions(name: "x")
        #expect(options.bakedSettings(from: all) == EnhanceSettings())

        options.bakeEffects = true
        options.bakeGrade = true
        let baked = options.bakedSettings(from: all)
        #expect(baked.fieldOrder == nil)
        #expect(baked.denoiseStrength == 0.5)
        #expect(baked.sharpen == 0.4)
        #expect(baked.grade == grade)
    }

    @Test func inheritsWhatIsntBakedAndTurnsOffWhatIs() {
        let source = Clip(url: URL(filePath: "/a.mov"))
        source.sharpen = 0.4
        source.grade.exposure = 1
        source.deinterlace = true

        let inherited = Clip(url: URL(filePath: "/b.mov"))
        var options = NewSourceOptions(name: "b")
        options.bakeGrade = true
        inherited.grade.exposure = 0.5  // as if loading had set something
        source.passSettings(to: inherited, options: options, marks: (1, 2))
        #expect(inherited.sharpen == 0.4)
        #expect(inherited.deinterlace)
        #expect(inherited.grade.isIdentity)  // baked, so off on the new clip
        #expect(inherited.inPoint == nil)  // trimmed, so no marks

        let plain = Clip(url: URL(filePath: "/c.mov"))
        options.inherit = false
        options.trimToMarks = false
        source.passSettings(to: plain, options: options, marks: (1, 2))
        #expect(plain.sharpen == 0)
        #expect(!plain.deinterlace)
        #expect(plain.inPoint == nil)

        let whole = Clip(url: URL(filePath: "/d.mov"))
        options.inherit = true
        source.passSettings(to: whole, options: options, marks: (1, 2))
        #expect(whole.inPoint == 1 && whole.outPoint == 2)  // whole file keeps the marks
    }

    @Test func savesTrimmedFileAndImportsIt() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "source", seconds: 3, size: CGSize(width: 320, height: 180))
        let store = ProjectStore(exporter: ExportManager.test("NewSourceVideoTests"))
        store.projectURL = dir.appending(path: "Project.swiftcut")
        let source = try #require(store.importFiles([url]).first)
        for _ in 0..<100 where !source.isLoaded { try await Task.sleep(for: .milliseconds(50)) }
        source.sharpen = 0.3

        var options = NewSourceOptions(name: "Trimmed")
        options.presetID = ExportPreset.builtIn("MP4 (H.264)").id
        store.makeSourceVideo(from: source, range: 1...2, marks: (1, 2), options: options)
        for _ in 0..<300 {
            if let new = store.clips.last, new !== source, new.isLoaded, new.sharpen == 0.3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let new = try #require(store.clips.last)
        #expect(new !== source)
        #expect(new.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(abs(new.duration - 1) < 0.1)
        #expect(new.sharpen == 0.3)  // inherited
    }
}
