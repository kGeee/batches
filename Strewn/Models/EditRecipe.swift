import CoreGraphics
import Foundation

/// A non-destructive edit: a small list of settings applied on top of the untouched
/// original (the DNG for Strewn captures, the original file for imports). Stored on the
/// Photo, in the backend, and in Photos as adjustment data, so edits can always be
/// changed or reverted.
struct EditRecipe: Codable, Hashable, Sendable {
    var lookID: String = "neutral"
    var lookStrength: Float = 1
    // Light
    var exposure: Float = 0          // EV
    var contrast: Float = 0          // -1 … 1 for everything below unless noted
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    // Color
    var temperature: Float = 0       // relative to the develop's white balance; + is warmer
    var tint: Float = 0              // + is more magenta
    var vibrance: Float = 0
    var saturation: Float = 0
    // Effects
    var grain: Float = 0             // 0 … 1
    var vignette: Float = 0
    var fade: Float = 0              // 0 … 1
    // Geometry. Original keeps the full frame; cropping only ever happens when the user picks it.
    var aspect: Aspect = .original
    var straighten: Float = 0        // degrees, -10 … 10
    /// Everything about how this photo's source was developed that must never drift:
    /// pipeline version, RAW decoder, metering, white balance, camera profile and grain seed.
    /// Set once at capture (or on first edit) and kept through edits, pastes and reverts.
    var develop: DevelopState? = nil

    static let identity = EditRecipe()
    static let formatIdentifier = "com.example.strewn.recipe"
    static let formatVersion = "2"

    /// True when no adjustment or look is applied. The develop state doesn't count: it
    /// describes the original, not an edit.
    var isIdentity: Bool {
        var plain = self
        plain.develop = nil
        return plain == .identity
    }

    /// Copy/paste carries the look and adjustments but leaves each photo's own crop and its
    /// own develop state (metering, white balance, camera profile, grain seed) alone.
    func pasting(_ other: EditRecipe) -> EditRecipe {
        var result = other
        result.aspect = aspect
        result.straighten = straighten
        result.develop = develop
        return result
    }

    /// Back to the original without forgetting how the original was developed. Use this
    /// rather than `.identity` so a revert re-renders exactly like the untouched capture.
    func reverted() -> EditRecipe {
        var result = EditRecipe.identity
        result.develop = develop
        return result
    }

    enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
        case original, r3x2 = "3:2", r4x5 = "4:5", r1x1 = "1:1", r16x9 = "16:9", r9x16 = "9:16"
        var id: String { rawValue }
        var title: String { self == .original ? "Original" : rawValue }
        /// Width / height, or nil to keep the photo's own shape.
        var ratio: CGFloat? {
            switch self {
            case .original: nil
            case .r3x2: 3.0 / 2.0
            case .r4x5: 4.0 / 5.0
            case .r1x1: 1
            case .r16x9: 16.0 / 9.0
            case .r9x16: 9.0 / 16.0
            }
        }
    }
}

// Decoding tolerates missing keys, so recipes saved by older builds (and by the web or
// another platform later) still open, and new fields can be added without a migration.
extension EditRecipe {
    private enum CodingKeys: String, CodingKey {
        case lookID, lookStrength, exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation, grain, vignette, fade, aspect, straighten, develop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditRecipe.identity
        func f(_ key: CodingKeys, _ fallback: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: key) ?? fallback }
        lookID = try c.decodeIfPresent(String.self, forKey: .lookID) ?? d.lookID
        lookStrength = try f(.lookStrength, d.lookStrength)
        exposure = try f(.exposure, 0)
        contrast = try f(.contrast, 0)
        highlights = try f(.highlights, 0)
        shadows = try f(.shadows, 0)
        whites = try f(.whites, 0)
        blacks = try f(.blacks, 0)
        temperature = try f(.temperature, 0)
        tint = try f(.tint, 0)
        vibrance = try f(.vibrance, 0)
        saturation = try f(.saturation, 0)
        grain = try f(.grain, 0)
        vignette = try f(.vignette, 0)
        fade = try f(.fade, 0)
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? .original
        straighten = try f(.straighten, 0)
        develop = try c.decodeIfPresent(DevelopState.self, forKey: .develop)
    }
}

/// The frozen half of a recipe. Anything the pipeline would otherwise decide automatically
/// (and could therefore decide differently on another phone, OS or app version) is decided
/// once and written down here.
struct DevelopState: Codable, Hashable, Sendable {
    enum SourceKind: String, Codable, Sendable { case bayerRAW, proRAW, processed }

    enum WhiteBalance: Codable, Hashable, Sendable {
        /// The film stock's own balance (daylight 5500 K, tungsten 3200 K), like real film.
        case film
        /// A fixed color temperature from the WB dial.
        case kelvin(Float, tint: Float)
        /// The camera's auto white balance at the moment of capture, frozen as a chromaticity.
        case asShot(x: Float, y: Float)
    }

    /// The color pipeline this photo renders with. Never changed after it's set.
    var pipelineVersion: Int
    var source: SourceKind
    /// CIRAWDecoderVersion raw value (for example "8.dng"), pinned so demosaic and noise
    /// reduction can't change under an OS update.
    var decoderVersion: String?
    /// The DNG's own BaselineExposure, read once.
    var baselineExposure: Float?
    /// Strewn's metering result plus the shooter's exposure compensation, in stops.
    var meteringEV: Float = 0
    var whiteBalance: WhiteBalance = .film
    /// Camera profile key and the matrix it resolved to (row-major 3×3, linear Rec.2020).
    var profileKey: String?
    var profileMatrix: [Float]?
    /// Grain pattern offset, so re-renders reproduce the same grain.
    var grainSeed: UInt32 = 0
}
