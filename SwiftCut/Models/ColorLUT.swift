import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A 3D color lookup table (LUT): for any input color, the color it becomes.
/// Stored as RGBA Float32 values with red changing fastest, which is the order
/// both `.cube` files and Core Image's color cube filter use.
nonisolated final class ColorLUT: Identifiable, Hashable, @unchecked Sendable {
    enum Kind: String, Sendable {
        /// Converts iPhone Apple Log footage to normal-looking video.
        case appleLog
        /// A look for normal (Rec. 709) video.
        case look
        /// Imported by the user.
        case imported
    }

    let id: UUID
    let name: String
    let kind: Kind
    /// One line about what it does.
    let summary: String
    /// Points along each side of the cube.
    let size: Int
    /// size³ RGBA Float32 values.
    let data: Data

    init(id: UUID, name: String, kind: Kind, summary: String, size: Int, data: Data) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.size = size
        self.data = data
    }

    var isBuiltIn: Bool { kind != .imported }

    static func == (a: ColorLUT, b: ColorLUT) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Builds a LUT by running `transform` on every point of the cube.
    static func generate(id: UUID, name: String, kind: Kind, summary: String, size: Int = 33,
                         transform: (SIMD3<Double>) -> SIMD3<Double>) -> ColorLUT {
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let scale = 1 / Double(size - 1)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(SIMD3(Double(r) * scale, Double(g) * scale, Double(b) * scale))
                    values[i] = Float(min(max(out.x, 0), 1))
                    values[i + 1] = Float(min(max(out.y, 0), 1))
                    values[i + 2] = Float(min(max(out.z, 0), 1))
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return ColorLUT(id: id, name: name, kind: kind, summary: summary, size: size,
                        data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// The color `input` becomes (smoothly blended between cube points).
    func apply(_ input: SIMD3<Double>) -> SIMD3<Double> {
        data.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: Float.self)
            let n = size
            let p = SIMD3(min(max(input.x, 0), 1), min(max(input.y, 0), 1), min(max(input.z, 0), 1)) * Double(n - 1)
            let lo = SIMD3(Int(p.x), Int(p.y), Int(p.z))
            let hi = SIMD3(min(lo.x + 1, n - 1), min(lo.y + 1, n - 1), min(lo.z + 1, n - 1))
            let f = p - SIMD3(Double(lo.x), Double(lo.y), Double(lo.z))
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
                let i = ((b * n + g) * n + r) * 4
                return SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
            }
            let c00 = at(lo.x, lo.y, lo.z) * (1 - f.x) + at(hi.x, lo.y, lo.z) * f.x
            let c10 = at(lo.x, hi.y, lo.z) * (1 - f.x) + at(hi.x, hi.y, lo.z) * f.x
            let c01 = at(lo.x, lo.y, hi.z) * (1 - f.x) + at(hi.x, lo.y, hi.z) * f.x
            let c11 = at(lo.x, hi.y, hi.z) * (1 - f.x) + at(hi.x, hi.y, hi.z) * f.x
            let c0 = c00 * (1 - f.y) + c10 * f.y
            let c1 = c01 * (1 - f.y) + c11 * f.y
            return c0 * (1 - f.z) + c1 * f.z
        }
    }
}

// MARK: - .cube files

/// Reads and writes `.cube` LUT files (the standard used by Resolve, Final Cut, Premiere, and others).
nonisolated enum CubeFile {
    enum ReadError: LocalizedError {
        case notACube
        case wrongCount(expected: Int, found: Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notACube: "This isn't a .cube LUT file (it has no LUT_3D_SIZE or LUT_1D_SIZE line)."
            case .wrongCount(let expected, let found): "The LUT is incomplete: it should have \(expected) color rows but has \(found)."
            case .tooLarge: "This LUT is larger than SwiftCut supports (up to 128 points per side)."
            }
        }
    }

    static let contentType = UTType(filenameExtension: "cube", conformingTo: .data) ?? .data

    /// The LUT's contents. `title` is the TITLE line, if any.
    static func read(_ text: String) throws -> (title: String?, size: Int, data: Data) {
        var title: String?
        var size3D: Int?
        var size1D: Int?
        var domainMin = SIMD3<Double>(0, 0, 0)
        var domainMax = SIMD3<Double>(1, 1, 1)
        var rows: [SIMD3<Double>] = []
        rows.reserveCapacity(36_000)

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = parts.first else { continue }
            switch keyword.uppercased() {
            case "TITLE":
                if let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end {
                    title = String(line[line.index(after: start)..<end])
                } else {
                    title = parts.dropFirst().joined(separator: " ")
                }
            case "LUT_3D_SIZE":
                size3D = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE":
                size1D = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN":
                if let v = vector(parts.dropFirst()) { domainMin = v }
            case "DOMAIN_MAX":
                if let v = vector(parts.dropFirst()) { domainMax = v }
            default:
                if let v = vector(parts[...]) { rows.append(v) }
                // Other keywords (LUT_3D_INPUT_RANGE and so on) are skipped.
            }
        }

        // The file's cube covers DOMAIN_MIN…DOMAIN_MAX; SwiftCut's cubes always cover 0…1.
        let range = domainMax - domainMin

        if let n = size3D {
            guard n >= 2 else { throw ReadError.notACube }
            guard n <= 128 else { throw ReadError.tooLarge }
            guard rows.count == n * n * n else { throw ReadError.wrongCount(expected: n * n * n, found: rows.count) }
            let source = ColorLUT(id: UUID(), name: "", kind: .imported, summary: "", size: n,
                                  data: pack(rows))
            if domainMin == SIMD3(0, 0, 0), domainMax == SIMD3(1, 1, 1) {
                return (title, n, source.data)
            }
            // Resample so the cube covers 0…1.
            let resampled = ColorLUT.generate(id: UUID(), name: "", kind: .imported, summary: "", size: n) { input in
                let p = (input - domainMin) / SIMD3(max(range.x, 1e-6), max(range.y, 1e-6), max(range.z, 1e-6))
                return source.apply(p)
            }
            return (title, n, resampled.data)
        }
        if let n = size1D {
            guard n >= 2 else { throw ReadError.notACube }
            guard rows.count == n else { throw ReadError.wrongCount(expected: n, found: rows.count) }
            // A 1D LUT changes each channel on its own; build the equivalent 3D cube.
            func curve(_ x: Double, _ channel: Int) -> Double {
                let t = min(max((x - domainMin[channel]) / max(range[channel], 1e-6), 0), 1) * Double(n - 1)
                let i = min(Int(t), n - 2)
                let f = t - Double(i)
                return rows[i][channel] * (1 - f) + rows[i + 1][channel] * f
            }
            let cube = ColorLUT.generate(id: UUID(), name: "", kind: .imported, summary: "", size: 33) { input in
                SIMD3(curve(input.x, 0), curve(input.y, 1), curve(input.z, 2))
            }
            return (title, 33, cube.data)
        }
        throw ReadError.notACube
    }

    /// A `.cube` file for `lut`.
    static func write(_ lut: ColorLUT) -> String {
        var text = "# Exported from SwiftCut\nTITLE \"\(lut.name.replacingOccurrences(of: "\"", with: "'"))\"\n"
        text += "LUT_3D_SIZE \(lut.size)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n\n"
        lut.data.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: Float.self)
            var lines: [String] = []
            lines.reserveCapacity(lut.size * lut.size * lut.size)
            for i in stride(from: 0, to: v.count, by: 4) {
                lines.append(String(format: "%.6f %.6f %.6f", v[i], v[i + 1], v[i + 2]))
            }
            text += lines.joined(separator: "\n")
        }
        return text + "\n"
    }

    private static func vector(_ parts: ArraySlice<Substring>) -> SIMD3<Double>? {
        guard parts.count >= 3, let r = Double(parts[parts.startIndex]),
              let g = Double(parts[parts.startIndex + 1]), let b = Double(parts[parts.startIndex + 2]) else { return nil }
        return SIMD3(r, g, b)
    }

    private static func pack(_ rows: [SIMD3<Double>]) -> Data {
        var values = [Float]()
        values.reserveCapacity(rows.count * 4)
        for row in rows {
            values += [Float(row.x), Float(row.y), Float(row.z), 1]
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Built-in LUTs

/// Math for the built-in LUTs.
nonisolated enum ColorMath {
    // Apple Log, from Apple's "Apple Log Profile" white paper.
    private static let r0 = -0.05641088, rt = 0.01, c = 47.28711236
    private static let beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
    private static let pt = c * (rt - r0) * (rt - r0)

    /// Apple Log code value (0…1) → scene light (0.18 is middle gray).
    static func appleLogToLinear(_ p: Double) -> Double {
        if p >= pt { return pow(2, (p - delta) / gamma) - beta }
        if p >= 0 { return (p / c).squareRoot() + r0 }
        return r0
    }

    /// Scene light → Apple Log code value.
    static func linearToAppleLog(_ r: Double) -> Double {
        if r >= rt { return gamma * log2(r + beta) + delta }
        if r >= r0 { return c * (r - r0) * (r - r0) }
        return 0
    }

    /// Apple Log uses Rec. 2020 primaries; normal video uses Rec. 709.
    static func rec2020ToRec709(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            1.6605 * v.x - 0.5876 * v.y - 0.0728 * v.z,
            -0.1246 * v.x + 1.1329 * v.y - 0.0083 * v.z,
            -0.0182 * v.x - 0.1006 * v.y + 1.1187 * v.z
        )
    }

    /// Film-like highlight roll-off (the common ACES fit), scene light → display light.
    static func filmicToneMap(_ x: Double) -> Double {
        let x = max(x, 0)
        return min(max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0), 1)
    }

    /// Display light → Rec. 709 video code value (BT.1886, gamma 2.4).
    static func encodeDisplay(_ x: Double) -> Double { pow(min(max(x, 0), 1), 1 / 2.4) }
    static func decodeDisplay(_ x: Double) -> Double { pow(min(max(x, 0), 1), 2.4) }

    static func luma(_ v: SIMD3<Double>) -> Double { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }

    static func saturate(_ v: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> {
        let y = luma(v)
        return SIMD3(repeating: y) + (v - SIMD3(repeating: y)) * amount
    }

    /// Gentle S-curve; 0 leaves it alone.
    static func contrast(_ v: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> {
        func s(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            let smooth = x * x * (3 - 2 * x)
            return x + (smooth - x) * amount
        }
        return SIMD3(s(v.x), s(v.y), s(v.z))
    }

    /// Apple Log code values → Rec. 709 video, with a film-like roll-off.
    static func appleLogToRec709(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let scene = SIMD3(appleLogToLinear(v.x), appleLogToLinear(v.y), appleLogToLinear(v.z))
        let rec709 = rec2020ToRec709(scene)
        // 0.6 exposure puts middle gray (0.18) at the usual video level (about 44%).
        return SIMD3(encodeDisplay(filmicToneMap(rec709.x * 0.6)),
                     encodeDisplay(filmicToneMap(rec709.y * 0.6)),
                     encodeDisplay(filmicToneMap(rec709.z * 0.6)))
    }
}

nonisolated extension ColorLUT {
    /// LUTs that come with SwiftCut.
    static let builtIns: [ColorLUT] = [
        generate(id: UUID(uuidString: "32AA85EE-7E2E-4F78-BC35-34375C556DC0")!,
                 name: "Apple Log → Rec. 709", kind: .appleLog,
                 summary: "Turns iPhone Apple Log footage into normal-looking video, with soft highlights.") {
            ColorMath.appleLogToRec709($0)
        },
        generate(id: UUID(uuidString: "8E7422E1-DC32-4BD7-9018-DCF9C4421944")!,
                 name: "Apple Log → Rec. 709 (Low Contrast)", kind: .appleLog,
                 summary: "A flatter conversion that keeps more shadow and highlight detail for grading.") { input in
            let standard = ColorMath.appleLogToRec709(input)
            return standard * 0.7 + ColorMath.saturate(input, 0.8) * 0.3
        },
        generate(id: UUID(uuidString: "865C2566-A527-4DEE-B9E4-C84F178CE5D2")!,
                 name: "Apple Log → Rec. 709 (Vivid)", kind: .appleLog,
                 summary: "A punchier conversion with more color and contrast.") { input in
            ColorMath.contrast(ColorMath.saturate(ColorMath.appleLogToRec709(input), 1.25), 0.25)
        },
        generate(id: UUID(uuidString: "72CC22C4-FDBA-4B17-9716-F693309613B6")!,
                 name: "Warm", kind: .look, summary: "Golden, sunny tones.") { v in
            SIMD3(v.x * 1.05 + 0.015, v.y * 1.01 + 0.005, v.z * 0.9)
        },
        generate(id: UUID(uuidString: "7E33FCB5-0D6C-49AD-B7F4-851B76E6383B")!,
                 name: "Cool", kind: .look, summary: "Crisp blue tones.") { v in
            SIMD3(v.x * 0.93, v.y * 1.0 + 0.005, v.z * 1.06 + 0.02)
        },
        generate(id: UUID(uuidString: "E206F71D-75A4-4B6D-B889-B3E47BD51D5E")!,
                 name: "Teal & Orange", kind: .look, summary: "Teal shadows and warm skin tones, the classic movie look.") { v in
            let y = ColorMath.luma(v)
            let shadow = max(0, 1 - y * 2), highlight = max(0, y * 2 - 1)
            let toned = v + SIMD3(-0.06, 0.01, 0.06) * shadow + SIMD3(0.06, 0.015, -0.07) * (highlight + 0.3 * (1 - shadow - highlight))
            return ColorMath.contrast(ColorMath.saturate(toned, 1.1), 0.2)
        },
        generate(id: UUID(uuidString: "246882A9-D5A0-4646-AF7B-ABED732267DE")!,
                 name: "Faded Film", kind: .look, summary: "Soft lifted blacks and muted color, like an old print.") { v in
            let faded = SIMD3(repeating: 0.07) + ColorMath.saturate(v, 0.75) * 0.87
            return faded + SIMD3(0.015, 0.005, -0.01)
        },
        generate(id: UUID(uuidString: "E0DA9746-7E26-4A72-A488-77292F8F3AD1")!,
                 name: "High Contrast", kind: .look, summary: "Deeper blacks, brighter whites, a little more color.") { v in
            ColorMath.contrast(ColorMath.saturate(v, 1.1), 0.45)
        },
        generate(id: UUID(uuidString: "692675AC-15CB-4B5D-B781-B79D626E4E5D")!,
                 name: "Black & White", kind: .look, summary: "Rich black and white.") { v in
            ColorMath.contrast(SIMD3(repeating: ColorMath.luma(v)), 0.2)
        },
    ]
}

/// What a clip's LUT does in the effects pipeline.
nonisolated struct AppliedLUT: Hashable, Sendable {
    let lut: ColorLUT
    /// 0…1: how much of the LUT's change to use.
    var intensity: Float
}

// MARK: - Library

/// The built-in LUTs plus any the user imported (kept as .cube files in Application Support).
@Observable
final class LUTLibrary {
    static let shared = LUTLibrary()

    private(set) var imported: [ColorLUT] = []
    let directory: URL

    var all: [ColorLUT] { ColorLUT.builtIns + imported }
    var appleLog: [ColorLUT] { ColorLUT.builtIns.filter { $0.kind == .appleLog } }
    var looks: [ColorLUT] { ColorLUT.builtIns.filter { $0.kind == .look } }

    func lut(id: UUID?) -> ColorLUT? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// `directory` is replaceable for tests.
    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "LUTs", directoryHint: .isDirectory)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        imported = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .compactMap { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      let cube = try? CubeFile.read(text) else { return nil }
                return ColorLUT(id: id, name: cube.title ?? "Imported LUT", kind: .imported,
                                summary: "Imported \(cube.size)-point LUT", size: cube.size, data: cube.data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds a `.cube` file. Its name comes from its TITLE, or the file name.
    @discardableResult
    func importFile(_ url: URL) throws -> ColorLUT {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let cube = try CubeFile.read(text)
        let name = cube.title?.isEmpty == false ? cube.title! : url.deletingPathExtension().lastPathComponent
        let lut = ColorLUT(id: UUID(), name: name, kind: .imported, summary: "Imported \(cube.size)-point LUT",
                           size: cube.size, data: cube.data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CubeFile.write(lut).write(to: directory.appending(path: "\(lut.id.uuidString).cube"), atomically: true, encoding: .utf8)
        reload()
        return lut
    }

    func delete(_ ids: Set<UUID>) {
        for lut in imported where ids.contains(lut.id) {
            try? FileManager.default.removeItem(at: directory.appending(path: "\(lut.id.uuidString).cube"))
        }
        reload()
    }
}

/// A LUT to save as a `.cube` file.
nonisolated struct CubeDocument: FileDocument {
    static let readableContentTypes: [UTType] = [CubeFile.contentType]
    let lut: ColorLUT

    init(lut: ColorLUT) { self.lut = lut }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(CubeFile.write(lut).utf8))
    }
}

// MARK: - Settings

/// Color choices from Settings › Color.
nonisolated enum ColorSettings {
    static let autoLUTKey = "appleLogAutoLUT"
    static let exportTagsKey = "exportColorTags"

    /// How exports are labeled for color.
    enum ExportTags: String, CaseIterable, Identifiable, Sendable {
        /// Rec. 601 for standard definition, Rec. 709 for HD and up.
        case automatic
        case alwaysRec709

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic (SD: Rec. 601, HD: Rec. 709)"
            case .alwaysRec709: "Always Rec. 709"
            }
        }
    }

    static var exportTags: ExportTags {
        ExportTags(rawValue: UserDefaults.standard.string(forKey: exportTagsKey) ?? "") ?? .automatic
    }

    /// LUT applied to newly imported Apple Log clips, or `nil` for none. Defaults to the standard conversion.
    static var autoLUTForAppleLog: UUID? {
        // Not set yet: the standard conversion. "none": leave Apple Log clips as they are.
        guard let raw = UserDefaults.standard.string(forKey: autoLUTKey) else { return ColorLUT.builtIns[0].id }
        return UUID(uuidString: raw)
    }
}

// MARK: - Previews

/// Small swatches showing what a LUT does, for lists and menus.
enum LUTSwatch {
    private static var cache: [UUID: NSImage] = [:]

    static func image(for lut: ColorLUT, size: CGSize = CGSize(width: 96, height: 28)) -> NSImage {
        if let cached = cache[lut.id], cached.size == size { return cached }
        let width = Int(size.width) * 2, height = Int(size.height) * 2
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                // Top: a rainbow of moderately saturated colors. Bottom: black to white.
                var display: SIMD3<Double>
                if y < height * 2 / 3 {
                    display = hsv(t, 0.55, 0.85 - 0.35 * Double(y) / Double(height))
                } else {
                    display = SIMD3(repeating: t)
                }
                var input = display
                if lut.kind == .appleLog {
                    // Show what the LUT does to Apple Log footage of this scene.
                    let scene = SIMD3(ColorMath.decodeDisplay(display.x), ColorMath.decodeDisplay(display.y),
                                      ColorMath.decodeDisplay(display.z)) / 0.6 * 0.5
                    input = SIMD3(ColorMath.linearToAppleLog(scene.x), ColorMath.linearToAppleLog(scene.y),
                                  ColorMath.linearToAppleLog(scene.z))
                }
                let out = lut.apply(input)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(min(max(out.x, 0), 1) * 255)
                pixels[i + 1] = UInt8(min(max(out.y, 0), 1) * 255)
                pixels[i + 2] = UInt8(min(max(out.z, 0), 1) * 255)
            }
        }
        let image: NSImage
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            image = NSImage(cgImage: cg, size: size)
        } else {
            image = NSImage(size: size)
        }
        cache[lut.id] = image
        return image
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        let k = SIMD3<Double>(5, 3, 1)
        func f(_ n: Double) -> Double {
            let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        return SIMD3(f(k.x), f(k.y), f(k.z))
    }
}
