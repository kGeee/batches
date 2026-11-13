import SwiftUI

/// The expanded form of a film-framed pile: one continuous strip running down the screen, frames
/// connected end to end and perforations down both sides. Each frame is nearly the full screen
/// width, capped so a tall portrait still fits on one screen. Nothing is cropped.
///
/// The roll only runs down. Batches saved as sideways (FrameStyle.rollDirection) open down too;
/// the field stays so their frames still decode.
struct FilmRollView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let availableHeight: CGFloat
    let width: CGFloat
    var onView: (Photo) -> Void

    private var border: CGFloat { collection.frame.borderWidth }
    private var band: CGFloat { border * 1.1 + 22 }
    private var holes: CGFloat { max(7, border * 0.55) }

    var body: some View {
        let pileFrames = FilmRollLayout.frames(for: collection).map(\.id)
        let maxFrameHeight = availableHeight - 110          // leave room for the caption
        return LazyVStack(spacing: max(14, border * 0.8)) {
            ForEach(Array(collection.photos.enumerated()), id: \.element.id) { index, photo in
                VStack(spacing: 6) {
                    frame(photo, pileIndex: pileFrames.firstIndex(of: photo.id))
                        .frame(maxHeight: maxFrameHeight)
                    PhotoMetaRow(collection: collection, photo: photo, index: index)
                        .foregroundStyle(Color.filmEdge)
                        .environment(\.colorScheme, .dark)
                }
            }
        }
        .padding(.horizontal, band)
        .padding(.vertical, 20)
        .background(Color.film)
        .overlay { SprocketHoles(holeHeight: holes, inset: band * 0.26, axis: .vertical) }
    }

    // MARK: Shared

    /// One frame on the roll: the photo at its own aspect, tied to its pile frame by matched geometry.
    private func frame(_ photo: Photo, pileIndex: Int?) -> some View {
        PhotoImage(photo: photo)
            .matchedGeometryEffect(id: photo.id, in: namespace)
            .transition(pileIndex.map { AnyTransition.pileRotation(FilmRollLayout.angle(at: $0)) } ?? .opacity)
            .onTapGesture { onView(photo) }
    }
}
