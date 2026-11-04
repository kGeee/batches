import Foundation

/// Swift mirror of the kernel math in StrewnKernels.ci.metal, for the preview calibrator,
/// offline LUT building and unit tests. Keep the two in sync; both are frozen per version.
enum ToneCurve {
    static let middleGrey: Float = 0.18

    /// log2 range covered by the LUT encoding: 0.18 · 2^-8 … 0.18 · 2^+6.
    static let minStops: Float = -8
    static let rangeStops: Float = 14

    /// Rec.2020 luminance, the working space's own weights.
    static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2627 * r + 0.6780 * g + 0.0593 * b
    }

    static func stops(_ x: Float) -> Float { log2(max(x, 1e-6) / middleGrey) }

    static func encodeLog(_ x: Float) -> Float {
        min(max((log2(max(x, 1e-5) / middleGrey) - minStops) / rangeStops, 0), 1)
    }

    static func decodeLog(_ y: Float) -> Float {
        middleGrey * exp2(y * rangeStops + minStops)
    }

    /// strewnHD: stops from middle grey → print value 0…1.
    static func characteristic(_ e: Float, gamma: Float, toe: Float, shoulder: Float) -> Float {
        var y = 0.5 + 0.5 * tanh(e * 0.3 * gamma)
        y = y * y / (y + toe + 1e-5) * (1 + toe)
        let k = 1 + 2 * (1 - shoulder)
        let top = 1 - pow(max(1 - y, 0), k)
        let t = smoothstep(0.5, 1, y)
        return y + (top - y) * t
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
