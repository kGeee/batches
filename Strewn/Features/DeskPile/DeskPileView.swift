import SwiftUI

/// A collection shown collapsed: a loose stack of prints with the cover on top.
/// Each print carries a matchedGeometryEffect id equal to its photo id, so the gallery can
/// fly the same photo out of the pile and back.
struct DeskPileView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    var spread: CGFloat = 1
    @Environment(\.tiltedPiles) private var tilted

    var body: some View {
        if collection.frame.kind == .filmStrip {
            FilmRollPileView(collection: collection, namespace: namespace)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(collection.title), roll of \(collection.photos.count) photos")
                .accessibilityAddTraits(.isButton)
        } else {
            printPile
        }
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
