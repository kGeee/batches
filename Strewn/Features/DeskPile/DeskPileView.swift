import SwiftUI

/// A collection shown collapsed: a loose stack of prints with the cover on top.
/// Each print carries a matchedGeometryEffect id equal to its photo id, so the gallery can
/// fly the same photo out of the pile and back.
struct DeskPileView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    var spread: CGFloat = 1
    /// Width over height of the cover in the quiet (squared-up) pile. nil follows the cover's
    /// own shape, kept between a tall portrait and a wide landscape.
    var aspect: CGFloat? = 4 / 3
    @Environment(\.tiltedPiles) private var tilted

    var body: some View {
        // On the quiet desk a roll of film is a pile like any other; the roll only comes out when
        // piles are tilted, where the desk is playing at being a real table.
        if tilted && collection.frame.kind == .filmStrip {
            FilmRollPileView(collection: collection, namespace: namespace)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(collection.title), roll of \(collection.photos.count) photos")
                .accessibilityAddTraits(.isButton)
        } else if tilted {
            printPile
        } else {
            quietPile
        }
    }

    /// The shape of the first batch on the desk: the cover's own, within reason, when piles lie quiet.
    static func heroShape(_ collection: PhotoCollection, tilted: Bool) -> CGFloat {
        if tilted { return 3 / 2 }
        return min(1.9, max(0.8, collection.cover?.aspectRatio ?? 4 / 3))
    }

    /// The cover edge to edge, with the next two photos showing only as two paper edges
    /// behind it. Every photo in the stack keeps its matched id, so opening still flies them out.
    private var quietPile: some View {
        let stack = collection.pileStack()
        let cover = stack.last
        let shape = aspect ?? min(1.9, max(0.8, cover?.aspectRatio ?? 4 / 3))
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = max(3, min(5, h * 0.025))
            let under = Array(stack.dropLast())
            ZStack(alignment: .bottom) {
                ForEach(Array(under.enumerated()), id: \.element.id) { index, photo in
                    // Only the top two below the cover show; the rest wait, hidden, under it.
                    let depth = CGFloat(min(2, under.count - index))
                    Rectangle()
                        .fill(depth >= 2 ? Color.fogEdgeFar : Color.fogEdge)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .frame(width: w - depth * w * 0.045, height: h - step * 2)
                        .matchedGeometryEffect(id: photo.id, in: namespace)
                        .offset(y: -depth * step * spread)
                }
                if let cover {
                    PhotoImage(photo: cover)
                        .aspectRatio(cover.aspectRatio, contentMode: .fill)
                        .frame(width: w, height: h - step * 2)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .matchedGeometryEffect(id: cover.id, in: namespace)
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
        .aspectRatio(shape, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.title), \(collection.photos.count) photos")
        .accessibilityAddTraits(.isButton)
    }

    private var printPile: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stack = collection.pileStack()
            ZStack {
                ForEach(Array(stack.enumerated()), id: \.element.id) { index, photo in
                    let place = PileLayout.placement(for: photo, isTop: index == stack.count - 1, tilted: tilted)
                    PrintView(photo: photo, paper: side * 0.018)
                        .frame(width: side * place.widthFraction)
                        .matchedGeometryEffect(id: photo.id, in: namespace)
                        // Rotation is applied after the matched frame so the gallery can
                        // animate it separately (see PileRotation).
                        .rotationEffect(.degrees(place.angle.degrees * spread))
                        // position (not offset) so the matched frame lands where the print is.
                        .position(x: side / 2 + place.offset.width * side * spread,
                                  y: side / 2 + place.offset.height * side * spread)
                        .zIndex(Double(index))
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.title), \(collection.photos.count) photos")
        .accessibilityAddTraits(.isButton)
    }
}

/// One photographic print: the photo with a thin paper margin and a soft desk shadow.
struct PrintView: View {
    let photo: Photo
    var paper: CGFloat = 4

    var body: some View {
        PhotoImage(photo: photo)
            .padding(paper)
            // Shadow on the paper shape, not the photo, so it stays cheap while piles animate.
            .background {
                Rectangle()
                    .fill(Color.paper)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
            }
    }
}

/// Rotates a gallery photo from its pile angle to upright as it is inserted, and back as it
/// is removed. Paired with matchedGeometryEffect, which handles position and size.
struct PileRotation: ViewModifier {
    let angle: Angle
    func body(content: Content) -> some View { content.rotationEffect(angle) }
}

extension AnyTransition {
    static func pileRotation(_ angle: Angle) -> AnyTransition {
        .modifier(active: PileRotation(angle: angle), identity: PileRotation(angle: .zero))
    }
}
