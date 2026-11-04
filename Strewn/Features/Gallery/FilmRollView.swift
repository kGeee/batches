import SwiftUI

/// The expanded form of a film-framed pile: one continuous strip with frames connected end
/// to end and perforations running its whole length. Nothing is cropped.
///
/// - Down (default): the roll runs down the screen inside the gallery's vertical scroll.
///   Each frame is nearly the full screen width, capped so a tall portrait still fits on
///   one screen, with perforations down both sides and its caption printed on the film.
/// - Sideways: a horizontal strip that snaps frame by frame. All frames share one height,
///   the tallest that still shows a 3:2 frame whole.
struct FilmRollView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let availableHeight: CGFloat
    let width: CGFloat
    var onView: (Photo) -> Void

    @State private var direction: FrameStyle.RollDirection
    @State private var currentID: UUID?

    init(collection: PhotoCollection, namespace: Namespace.ID, availableHeight: CGFloat, width: CGFloat,
         onView: @escaping (Photo) -> Void) {
        self.collection = collection
        self.namespace = namespace
        self.availableHeight = availableHeight
        self.width = width
        self.onView = onView
        _direction = State(initialValue: collection.frame.roll)
    }

    private var border: CGFloat { collection.frame.borderWidth }
    private var band: CGFloat { border * 1.1 + 22 }
    private var holes: CGFloat { max(7, border * 0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A viewing preference, so friends can flip it too; the owner's choice is the default.
            Picker("Roll direction", selection: $direction) {
                Text("Down").tag(FrameStyle.RollDirection.down)
                Text("Sideways").tag(FrameStyle.RollDirection.sideways)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.horizontal, 14)

            switch direction {
            case .down: downRoll
            case .sideways: sidewaysRoll
            }
        }
        .sensoryFeedback(.selection, trigger: direction)
    }

    // MARK: Down

    private var downRoll: some View {
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

    // MARK: Sideways

    private var sidewaysRoll: some View {
        let pileFrames = FilmRollLayout.frames(for: collection).map(\.id)
        let frameHeight = max(140, min(availableHeight - band * 2 - 150, (width - 56) / 1.5))
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: max(8, border * 0.6)) {
                    ForEach(Array(collection.photos.enumerated()), id: \.element.id) { index, photo in
                        frame(photo, pileIndex: pileFrames.firstIndex(of: photo.id))
                            .frame(height: frameHeight)
                            .overlay(alignment: .bottomLeading) {
                                Text(String(format: "%02dA ▸", index + 1))
                                    .font(.system(size: 8.5, design: .monospaced)).kerning(1)
                                    .foregroundStyle(Color.filmEdge)
                                    .offset(y: band * 0.62)
                            }
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, band)
                .padding(.horizontal, 28)
                .background(Color.film)
                .overlay { SprocketHoles(holeHeight: holes, inset: band * 0.2) }
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID, anchor: .center)
            .scrollIndicators(.hidden)

            if let photo = currentPhoto, let index = collection.photos.firstIndex(of: photo) {
                PhotoMetaRow(collection: collection, photo: photo, index: index)
                    .padding(.horizontal, 14)
                    .sensoryFeedback(.selection, trigger: currentID)
            }
        }
    }

    // MARK: Shared

    /// One frame on the roll: the photo at its own aspect, tied to its pile frame by matched geometry.
    private func frame(_ photo: Photo, pileIndex: Int?) -> some View {
        PhotoImage(photo: photo)
            .matchedGeometryEffect(id: photo.id, in: namespace)
            .transition(pileIndex.map { AnyTransition.pileRotation(FilmRollLayout.angle(at: $0)) } ?? .opacity)
            .onTapGesture { onView(photo) }
    }

    private var currentPhoto: Photo? {
        collection.photos.first { $0.id == currentID } ?? collection.photos.first
    }
}
