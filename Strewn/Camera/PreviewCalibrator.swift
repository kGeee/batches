import Foundation

/// Makes the viewfinder match the developed photo, and gets better with every shot.
///
/// The viewfinder starts from the video feed, which has been through some of Apple's video
/// processing even with Log or global tone mapping. Each capture gives us the truth: the RAW,
/// developed by the real pipeline. Comparing the two pictures of the same moment, channel by
/// channel and tone by tone, tells us how this camera module's feed differs, and the preview
/// applies the opposite. Matching is done on sorted values (quantiles), not pixel by pixel,
/// so the video and photo don't need to line up exactly, and phone orientation doesn't matter.
///
/// Stored per camera module and feed encoding, on this device only.
final class PreviewCalibrator: @unchecked Sendable {
    /// Stops from middle grey where corrections are kept; matches strewnPreviewCorrect_v1.
    static let knotStops: [Float] = [-6, -4, -2, 0, 2, 4, 6]
    private static let quantiles: [Float] = [0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9, 0.95, 0.98]
    /// How far one shot moves the correction. Small, so one odd frame can't throw it off.
    private static let learningRate: Float = 0.3

    private let storageKey: String
    private let lock = NSLock()
    private var stored: [SIMD3<Float>]

    init(moduleKey: String) {
        storageKey = "strewn.previewCalibration.v1.\(moduleKey)"
        if let flat = UserDefaults.standard.array(forKey: storageKey) as? [Float], flat.count == 21 {
            stored = (0..<7).map { SIMD3(flat[$0 * 3], flat[$0 * 3 + 1], flat[$0 * 3 + 2]) }
        } else {
            stored = Array(repeating: .zero, count: 7)
        }
    }

    var knots: [SIMD3<Float>] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// - Parameters:
    ///   - preview: scene-linear Rec.2020 samples of the viewfinder frame, before correction.
    ///   - developed: scene-linear Rec.2020 samples of the developed RAW of the same moment.
    func learn(preview: [SIMD3<Float>], developed: [SIMD3<Float>]) {
        guard preview.count > 100, developed.count > 100 else { return }
        // Each picture is normalised by its own median brightness, so exposure differences
        // between the video frame and the photo don't count as a color error.
        let p = normalised(preview), d = normalised(developed)
        lock.lock(); defer { lock.unlock() }
        for ch in 0..<3 {
            let ps = p.map { $0[ch] }.sorted(), ds = d.map { $0[ch] }.sorted()
            let pairs = Self.quantiles.map { q -> (Float, Float) in
                (ps[Int(q * Float(ps.count - 1))], ds[Int(q * Float(ds.count - 1))])
            }
            guard let lo = pairs.first?.0, let hi = pairs.last?.0, hi - lo > 1 else { continue }
            for (i, knot) in Self.knotStops.enumerated() where knot >= lo - 1 && knot <= hi + 1 {
                let error = Self.interpolate(pairs, at: knot)
                stored[i][ch] += Self.learningRate * (error - stored[i][ch])
            }
        }
        UserDefaults.standard.set(stored.flatMap { [$0.x, $0.y, $0.z] }, forKey: storageKey)
    }

    func reset() {
        lock.lock(); stored = Array(repeating: .zero, count: 7); lock.unlock()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Per-channel stops from middle grey, shifted so the median luminance sits at 0.
    private func normalised(_ samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let stops = samples.map { SIMD3(ToneCurve.stops($0.x), ToneCurve.stops($0.y), ToneCurve.stops($0.z)) }
        let luma = samples.map { ToneCurve.stops(ToneCurve.luma($0.x, $0.y, $0.z)) }.sorted()
        let median = luma[luma.count / 2]
        return stops.map { $0 - SIMD3(repeating: median) }
    }

    /// (developed - preview) at a preview value, linear between quantile pairs.
    private static func interpolate(_ pairs: [(Float, Float)], at x: Float) -> Float {
        guard let first = pairs.first, let last = pairs.last else { return 0 }
        if x <= first.0 { return first.1 - first.0 }
        if x >= last.0 { return last.1 - last.0 }
        for (a, b) in zip(pairs, pairs.dropFirst()) where x <= b.0 {
            let t = b.0 > a.0 ? (x - a.0) / (b.0 - a.0) : 0
            return (a.1 - a.0) + t * ((b.1 - b.0) - (a.1 - a.0))
        }
        return last.1 - last.0
    }
}
