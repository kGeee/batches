import Foundation

/// A film stock: how it sees color (balance and dye crosstalk), how each dye layer responds
/// to light (its characteristic curve), and the physical side effects (halation, grain).
/// Every parameter works on scene-linear Rec.2020, so a look gives the same result on every
/// iPhone, in the viewfinder, the saved shot and any later re-edit.
///
/// The ids match the looks in the design mockup. The numbers are first guesses to tune on a
/// real phone against reference scans. Once a build ships, a stock's numbers are frozen for
/// that `PipelineVersion`: retune by adding the new numbers under the next version.
struct FilmLook: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String

    /// Light the stock is balanced for. With film white balance (the default) this is the
    /// develop's neutral point, so tungsten light looks warm on daylight stocks, like film.
    var balanceKelvin: Float = 5500
    /// Dye crosstalk, row-major 3×3 in linear Rec.2020. Rows sum to 1 so greys stay grey.
    var crosstalk: [Float] = FilmLook.identity
    /// Per dye layer slope (r, g, b). Unequal slopes give film's color crossovers.
    var gamma: SIMD3<Float> = .init(repeating: 1)
    /// Per dye layer speed difference in stops (r, g, b). Shifts color most in the midtones.
    var offset: SIMD3<Float> = .zero
    var toe: Float = 0.03
    var shoulder: Float = 0.85
    /// Print black and white, for faded or matte prints.
    var blackLift: Float = 0
    var whitePoint: Float = 1
    /// Red-orange glow around lights brighter than `halationThreshold` (scene-linear).
    var halation: Float = 0
    var halationRadius: Float = 0.005          // fraction of the frame's long side
    var halationTint: SIMD3<Float> = .init(1.0, 0.32, 0.12)
    var halationThreshold: Float = 1.4         // about 3 stops over middle grey
    /// Grain strength, and size as grain clumps across the frame's long side.
    var grain: Float = 0
    var grainSize: Float = 2400
    var grainChroma: Float = 0.15
    /// Optional creative 3D LUT in Resources/Looks, applied in log space before the curve.
    var lutResource: String? = nil

    static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Saturation as a crosstalk matrix around Rec.2020 luminance.
    static func saturation(_ s: Float) -> [Float] {
        let w: [Float] = [0.2627, 0.6780, 0.0593]
        var m = [Float](repeating: 0, count: 9)
        for row in 0..<3 { for col in 0..<3 { m[row * 3 + col] = (1 - s) * w[col] + (row == col ? s : 0) } }
        return m
    }

    /// Panchromatic black and white: every channel sees the same weighted mix.
    static func monochrome(_ w: SIMD3<Float>) -> [Float] {
        let n = w / (w.x + w.y + w.z)
        return [n.x, n.y, n.z, n.x, n.y, n.z, n.x, n.y, n.z]
    }

    // MARK: Stocks (PipelineVersion 1)

    static let all: [FilmLook] = [
        FilmLook(id: "neutral", name: "Neutral", summary: "Flat and faithful. Best for editing later.",
                 crosstalk: saturation(0.97), toe: 0.02, shoulder: 0.9),
        FilmLook(id: "warm", name: "Warm 160", summary: "Soft contrast, warm skin, gentle highlight roll-off.",
                 crosstalk: saturation(0.92), gamma: .init(0.95, 0.92, 0.88), offset: .init(0.06, 0, -0.08),
                 toe: 0.05, shoulder: 0.7, blackLift: 0.01, whitePoint: 0.985,
                 halation: 0.05, grain: 0.025, grainSize: 2400),
        FilmLook(id: "slide", name: "Slide 50", summary: "Dense blacks and saturated color, like slide film.",
                 crosstalk: saturation(1.3), gamma: .init(1.25, 1.2, 1.28), offset: .init(0, 0, 0.03),
                 toe: 0.0, shoulder: 0.95, grain: 0.01, grainSize: 3200),
        FilmLook(id: "tungsten", name: "Tungsten 800", summary: "Balanced for lamplight, red halation around bright lights.",
                 balanceKelvin: 3200, crosstalk: saturation(1.05), gamma: .init(1.05, 1.0, 0.97), offset: .init(0.05, 0, 0),
                 toe: 0.03, shoulder: 0.8, halation: 0.35, halationRadius: 0.006, grain: 0.045, grainSize: 1600),
        FilmLook(id: "mono", name: "Mono 400", summary: "Silver tones with deep shadows and visible grain.",
                 crosstalk: monochrome(.init(0.28, 0.62, 0.10)), gamma: .init(repeating: 1.15),
                 toe: 0.02, shoulder: 0.85, grain: 0.06, grainSize: 1500, grainChroma: 0),
        FilmLook(id: "faded", name: "Faded", summary: "Lifted blacks and pastel midtones.",
                 crosstalk: saturation(0.8), gamma: .init(repeating: 0.85), offset: .init(0.02, 0, 0.04),
                 toe: 0.08, shoulder: 0.7, blackLift: 0.06, whitePoint: 0.95, grain: 0.02)
    ]

    static let neutral = all[0]
    static func byID(_ id: String) -> FilmLook { all.first { $0.id == id } ?? neutral }

    /// A look applied at partial strength: every parameter moves from Neutral toward the look,
    /// so it is one render (no double develop) and still deterministic. White balance moves in
    /// mireds, which is how the eye judges color temperature steps.
    func atStrength(_ t: Float) -> FilmLook {
        guard t < 1, id != FilmLook.neutral.id else { return self }
        let n = FilmLook.neutral, k = max(0, t)
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
        func mixV(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * k }
        var out = self
        out.balanceKelvin = 1_000_000 / mix(1_000_000 / n.balanceKelvin, 1_000_000 / balanceKelvin)
        out.crosstalk = zip(n.crosstalk, crosstalk).map { mix($0, $1) }
        out.gamma = mixV(n.gamma, gamma)
        out.offset = mixV(n.offset, offset)
        out.toe = mix(n.toe, toe)
        out.shoulder = mix(n.shoulder, shoulder)
        out.blackLift = mix(n.blackLift, blackLift)
        out.whitePoint = mix(n.whitePoint, whitePoint)
        out.halation = mix(n.halation, halation)
        out.grain = mix(n.grain, grain)
        return out
    }
}
