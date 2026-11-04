import SwiftUI

/// Where each print lands in a desk pile. Derived from the photo's id, so a pile looks the
/// same every time and on every device, and only reshuffles when the cover changes.
struct PilePlacement {
    var angle: Angle
    /// Offset of the print's center from the pile center, as a fraction of the pile side.
    var offset: CGSize
    /// Print width as a fraction of the pile side. Prints keep their true aspect ratio,
    /// so panoramas are wide and portraits are narrow.
    var widthFraction: CGFloat
}

enum PileLayout {
    static func placement(for photo: Photo, isTop: Bool) -> PilePlacement {
        var rng = SeededRandom(seed: photo.id)
        let width: CGFloat = switch photo.orientation {
        case .portrait: 0.44
        case .square: 0.52
        case .landscape: 0.62
        case .panorama: 0.80
        }
        if isTop {
            return PilePlacement(angle: .degrees(rng.next(in: -4...4)),
                                 offset: CGSize(width: rng.next(in: -0.015...0.015), height: rng.next(in: -0.015...0.015)),
                                 widthFraction: width)
        }
        return PilePlacement(angle: .degrees(rng.next(in: -17...17)),
                             offset: CGSize(width: rng.next(in: -0.09...0.09), height: rng.next(in: -0.07...0.07)),
                             widthFraction: width)
    }
}

/// Small deterministic generator (SplitMix64) seeded from a UUID.
struct SeededRandom {
    private var state: UInt64

    init(seed: UUID) {
        let b = seed.uuid
        state = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
