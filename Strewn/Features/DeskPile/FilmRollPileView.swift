import SwiftUI

/// The collapsed form of a pile framed as film: a loose strip curling across the desk. Frames are chained end to end (no gaps), and each keeps its photo's own
/// shape, so wide frames make a longer strip.
struct FilmRollPileView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let frames = FilmRollLayout.frames(for: collection)
            let placed = FilmRollLayout.place(frames, side: side)
            ZStack {
                ForEach(Array(placed.enumerated()), id: \.element.photo.id) { index, item in
                    FilmFrameView(photo: item.photo, frameHeight: item.height, scale: side)
                        .matchedGeometryEffect(id: item.photo.id, in: namespace)
                        .rotationEffect(item.angle)
                        .position(item.center)
                        .zIndex(Double(placed.count - index))
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

enum FilmRollLayout {
    static let startAngle: Double = -6
    static let bends: [Double] = [0, 34, 52]

    /// Cover first, then the next frames on the roll.
    static func frames(for collection: PhotoCollection) -> [Photo] {
        guard let cover = collection.cover else { return [] }
        return Array(([cover] + collection.photos.filter { $0.id != cover.id }).prefix(bends.count))
    }

    /// Cumulative angle of the frame at `index` on the pulled-out strip.
    static func angle(at index: Int) -> Angle {
        .degrees(startAngle + bends.prefix(index + 1).reduce(0, +))
    }

    struct Placed { let photo: Photo; let center: CGPoint; let angle: Angle; let height: CGFloat }

    /// Walks along the strip: each frame starts where the previous one ended, turned by its bend.
    /// Wide photos make a long strip, so if it would run past the square it is drawn smaller
    /// until it fits, then centered.
    static func place(_ photos: [Photo], side: CGFloat) -> [Placed] {
        var height = side * 0.34
        var (placed, bounds) = walk(photos, side: side, height: height)
        for _ in 0..<3 {
            let fit = side * 0.94 / max(bounds.width, bounds.height, 1)
            guard fit < 0.99 else { break }
            height *= fit
            (placed, bounds) = walk(photos, side: side, height: height)
        }
        let shift = CGPoint(x: side / 2 - bounds.midX, y: side / 2 - bounds.midY)
        return placed.map { Placed(photo: $0.photo, center: CGPoint(x: $0.center.x + shift.x, y: $0.center.y + shift.y),
                                   angle: $0.angle, height: $0.height) }
    }

    private static func walk(_ photos: [Photo], side: CGFloat, height: CGFloat) -> ([Placed], CGRect) {
        var point = CGPoint.zero
        var result: [Placed] = []
        var bounds = CGRect.null
        for (i, photo) in photos.enumerated() {
            let angle = angle(at: i)
            let width = FilmFrameView.width(for: photo, frameHeight: height, scale: side)
            let dir = CGVector(dx: cos(angle.radians), dy: sin(angle.radians))
            let center = CGPoint(x: point.x + dir.dx * width / 2, y: point.y + dir.dy * width / 2)
            result.append(Placed(photo: photo, center: center, angle: angle, height: height))
            point = CGPoint(x: point.x + dir.dx * width, y: point.y + dir.dy * width)
            let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
                .applying(CGAffineTransform(rotationAngle: angle.radians))
            bounds = bounds.union(frame.offsetBy(dx: center.x, dy: center.y))
        }
        return (result, bounds)
    }
}

/// One frame of film at pile scale: the photo at its true aspect inside the black film base.
struct FilmFrameView: View {
    let photo: Photo
    let frameHeight: CGFloat
    let scale: CGFloat

    static func width(for photo: Photo, frameHeight: CGFloat, scale: CGFloat) -> CGFloat {
        (frameHeight - scale * 0.072) * photo.aspectRatio + scale * 0.016
    }

    var body: some View {
        PhotoImage(photo: photo)
            .frame(height: frameHeight - scale * 0.072)
            .padding(.horizontal, scale * 0.008)
            .padding(.vertical, scale * 0.036)
            .background { Rectangle().fill(Color.film).shadow(color: .black.opacity(0.25), radius: 5, y: 3) }
            .overlay { SprocketHoles(holeHeight: scale * 0.014, inset: scale * 0.01) }
    }
}
