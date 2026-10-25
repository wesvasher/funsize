import CoreImage
import Foundation
import simd

/// Color correction for a source video, applied after its LUT (so it works on normal-looking
/// video, even for log footage). Shared by all of the video's subclips.
///
/// Every value is 0 when untouched. More controls (color wheels, curves) are added as new fields:
/// they decode as untouched from projects saved before they existed, and `apply` runs them in order.
nonisolated struct ColorGrade: Codable, Hashable, Sendable {
    // Light
    /// Stops of light, −2…+2.
    var exposure = 0.0
    /// −1…+1: flatter … punchier.
    var contrast = 0.0
    /// −1…+1: recover bright areas … brighten them.
    var highlights = 0.0
    /// −1…+1: deepen dark areas … open them up.
    var shadows = 0.0

    // Color
    /// −1…+1: cooler (bluer) … warmer (more orange).
    var temperature = 0.0
    /// −1…+1: greener … more magenta.
    var tint = 0.0
    /// −1…+1: black and white … double.
    var saturation = 0.0
    /// −1…+1: like saturation, but mostly changes muted colors and leaves strong ones alone.
    var vibrance = 0.0

    init() {}

    init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
         temperature: Double = 0, tint: Double = 0, saturation: Double = 0, vibrance: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.temperature = temperature
        self.tint = tint
        self.saturation = saturation
        self.vibrance = vibrance
    }

    // Missing values (older projects) are untouched.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
    }

    var isIdentity: Bool { self == ColorGrade() }

    // MARK: Applying

    /// Grades one video color (Rec. 709 code values, 0…1).
    func apply(_ input: SIMD3<Double>) -> SIMD3<Double> {
        var v = simd_clamp(input, .zero, .one)

        // White balance and exposure change the light itself, so they work on linear values.
        if exposure != 0 || temperature != 0 || tint != 0 {
            var light = SIMD3(ColorMath.decodeDisplay(v.x), ColorMath.decodeDisplay(v.y), ColorMath.decodeDisplay(v.z))
            light *= whiteBalanceGains * pow(2, exposure)
            v = SIMD3(ColorMath.encodeDisplay(light.x), ColorMath.encodeDisplay(light.y), ColorMath.encodeDisplay(light.z))
        }

        if contrast != 0 {
            // Steeper or flatter around the middle; black and white stay where they are.
            let k = contrast >= 0 ? 1 + 1.5 * contrast : 1 + 0.6 * contrast
            func curve(_ x: Double) -> Double {
                let pivot = 0.5
                return x < pivot
                    ? pivot * pow(x / pivot, k)
                    : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), k)
            }
            v = SIMD3(curve(v.x), curve(v.y), curve(v.z))
        }

        if highlights != 0 || shadows != 0 {
            // Changes brightness only, keeping each color's hue.
            let luma = ColorMath.luma(v)
            var target = luma
            if shadows != 0 {
                // Strongest around the darker third, fading out by the brights.
                let dark: Double = 1 - luma
                let weight: Double = 6.75 * luma * dark * dark
                target += shadows * 0.22 * weight
            }
            if highlights != 0 {
                let weight: Double = Self.smoothstep(0.35, 1, luma)
                // Brightening eases off near white so it doesn't clip.
                let headroom: Double = highlights > 0 ? min(1, 2 * (1 - luma)) : 1
                target += highlights * 0.3 * weight * headroom
            }
            target = min(max(target, 0), 1)
            v = luma > 1e-4 ? v * (target / luma) : v + SIMD3(repeating: target - luma)
        }

        if saturation != 0 || vibrance != 0 {
            let luma = ColorMath.luma(v)
            var amount = 1 + saturation
            if vibrance != 0 {
                // How colorful this pixel already is: vibrance mostly moves muted colors.
                let chroma = min(1, ((v.max() - v.min()) * 1.5))
                amount *= 1 + vibrance * (1 - chroma)
            }
            v = SIMD3(repeating: luma) + (v - SIMD3(repeating: luma)) * max(0, amount)
        }

        return simd_clamp(v, .zero, .one)
    }

    /// Red, green, blue multipliers for Temperature and Tint, keeping overall brightness.
    private var whiteBalanceGains: SIMD3<Double> {
        let gains = SIMD3(1 + 0.25 * temperature, 1 - 0.18 * tint, 1 - 0.25 * temperature)
        return gains / ColorMath.luma(gains)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The grade as a color cube, so the video pipeline can apply it like a LUT.
    func makeLUT(name: String = "Grade", size: Int = 33) -> ColorLUT {
        ColorLUT.generate(id: UUID(), name: name, kind: .imported,
                          summary: "Saved from the inspector's Grade section", size: size) { apply($0) }
    }
}

/// Everything the color stage applies: the LUT (with its intensity), then the grade.
nonisolated struct ColorLook: Hashable, Sendable {
    var lut: AppliedLUT?
    var grade = ColorGrade()

    var isEmpty: Bool { lut == nil && grade.isIdentity }
}

/// The color the preview shows, changeable while a video plays: the frame renderer reads it
/// for every frame, so choosing a LUT or moving a slider doesn't rebuild the preview.
/// Safe to use from any thread.
nonisolated final class LiveColor: @unchecked Sendable {
    private let lock = NSLock()
    private var look: ColorLook
    private var cached: (grade: ColorGrade, lut: ColorLUT)?

    init(_ look: ColorLook = ColorLook()) {
        self.look = look
    }

    var value: ColorLook {
        get { lock.withLock { look } }
        set { lock.withLock { look = newValue } }
    }

    /// The look, plus its grade as a cube (`nil` when the grade changes nothing), read together
    /// so a frame never mixes two versions. The cube is built once per grade change.
    func snapshot() -> (look: ColorLook, gradeLUT: ColorLUT?) {
        lock.withLock {
            let grade = look.grade
            guard !grade.isIdentity else { return (look, nil) }
            if let cached, cached.grade == grade { return (look, cached.lut) }
            let lut = grade.makeLUT()
            cached = (grade, lut)
            return (look, lut)
        }
    }
}

/// Applies a LUT and grade to a picture with Core Image. Used for every video frame and for
/// the quick preview shown while dragging color sliders.
nonisolated enum ColorStage {
    /// `space` is the color space `image` is tagged with. The cubes work on its raw values
    /// (video code values, or Apple Log), which is what LUTs are made for.
    static func apply(_ image: CIImage, look: ColorLook, gradeLUT: ColorLUT?, space: CGColorSpace) throws -> CIImage {
        var image = image
        if let applied = look.lut {
            var graded = try cube(applied.lut, on: image, space: space)
            if applied.intensity < 0.999 {
                let mix = CIFilter(name: "CIMix")!
                mix.setValue(graded, forKey: kCIInputImageKey)
                mix.setValue(image, forKey: kCIInputBackgroundImageKey)
                mix.setValue(max(0, applied.intensity), forKey: kCIInputAmountKey)
                graded = mix.outputImage ?? graded
            }
            image = graded
        }
        if let gradeLUT {
            image = try cube(gradeLUT, on: image, space: space)
        }
        return image
    }

    private static func cube(_ lut: ColorLUT, on image: CIImage, space: CGColorSpace) throws -> CIImage {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(lut.size, forKey: "inputCubeDimension")
        filter.setValue(lut.data, forKey: "inputCubeData")
        filter.setValue(space, forKey: "inputColorSpace")
        guard let output = filter.outputImage else { throw EnhanceError.failed("Couldn't apply “\(lut.name)”.") }
        return output
    }
}
