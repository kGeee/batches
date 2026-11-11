import SwiftUI

/// The owner arranges a batch's board: drag a print anywhere, pinch or use the slider to size it,
/// twist or use the slider to tilt it. Prints keep their whole shape and stay inside the board's
/// width, so nothing is ever cropped. Done saves it for everyone viewing; Cancel leaves it as it was.
struct BoardEditorView: View {
    let collection: PhotoCollection
    /// Called with the new arrangement on Done.
    let onSave: ([UUID: BatchBoard.Placement]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @State private var placements: [UUID: BatchBoard.Placement] = [:]
    @State private var selected: UUID?
    /// What the print being touched looked like when each gesture began.
    @State private var dragStart: BatchBoard.Placement?
    @State private var pinchStart: BatchBoard.Placement?
    @State private var twistStart: BatchBoard.Placement?
    @State private var loaded = false

    private var frame: FrameStyle { collection.frame }
    private var photos: [Photo] { collection.photos }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let width = geo.size.width
                ScrollView {
                    canvas(width: width, minHeight: geo.size.height)
                }
                .scrollIndicators(.hidden)
                // Not onAppear: a full-screen cover can first lay out with no width at all, and
                // placements worked out from that would be wildly off.
                .onChange(of: width, initial: true) {
                    guard !loaded, width > 100 else { return }
                    loaded = true
                    placements = BatchBoard.resolved(collection.board, photos: photos, insets: frame.insets, width: width)
                }
                .safeAreaInset(edge: .bottom) { controls(width: width) }
            }
            .background { wall.ignoresSafeArea() }
            .navigationTitle("Arrange board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(placements)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: selected)
        }
        .tint(.strewnAccent)
        .environment(\.colorScheme, wallScheme ?? systemScheme)
    }

    private func canvas(width: CGFloat, minHeight: CGFloat) -> some View {
        // Room below the last print, so there's somewhere to drag to.
        let height = max(minHeight, BatchBoard.height(of: photos, placements: placements, insets: frame.insets, width: width) + minHeight * 0.5)
        return ZStack {
            // Tapping the empty board lets go of the selected print.
            Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                if let place = placements[photo.id] {
                    print(photo, index: index, place: place, width: width)
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func print(_ photo: Photo, index: Int, place: BatchBoard.Placement, width: CGFloat) -> some View {
        PhotoImage(photo: photo)
            .frame(width: BatchBoard.imageWidth(place, insets: frame.insets, boardWidth: width))
            .photoFrame(frame, caption: photo.caption, frameNumber: index + 1, captionFont: collection.font)
            .overlay {
                if selected == photo.id {
                    Rectangle().stroke(Color.strewnAccent, lineWidth: 2.5)
                        .accessibilityHidden(true)
                }
            }
            .rotationEffect(place.angle)
            .contentShape(Rectangle())
            .onTapGesture { select(photo) }
            // High priority so dragging a print moves it; dragging the bare board still scrolls.
            .highPriorityGesture(move(photo, width: width))
            .simultaneousGesture(resize(photo, width: width))
            .simultaneousGesture(twist(photo, width: width))
            .position(x: place.x * width, y: place.y * width)
            .zIndex(Double(place.z))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo \(index + 1)")
            .accessibilityAddTraits(selected == photo.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Move up") { nudge(photo, dy: -0.05, width: width) }
            .accessibilityAction(named: "Move down") { nudge(photo, dy: 0.05, width: width) }
            .accessibilityAction(named: "Move left") { nudge(photo, dx: -0.05, width: width) }
            .accessibilityAction(named: "Move right") { nudge(photo, dx: 0.05, width: width) }
            .accessibilityAction(named: "Make bigger") { nudge(photo, dWidth: 0.05, width: width) }
            .accessibilityAction(named: "Make smaller") { nudge(photo, dWidth: -0.05, width: width) }
    }

    @ViewBuilder
    private func controls(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            if let selected, let photo = photos.first(where: { $0.id == selected }) {
                sliderRow("Size", value: Binding(
                    get: { Double(placements[selected]?.width ?? 0.5) },
                    set: { new in update(photo, width: width) { $0.width = CGFloat(new) } }),
                          in: Double(BatchBoard.widths.lowerBound)...Double(BatchBoard.widths.upperBound))
                sliderRow("Tilt", value: Binding(
                    get: { placements[selected]?.rotation ?? 0 },
                    set: { new in update(photo, width: width) { $0.rotation = abs(new) < 0.8 ? 0 : new } }),
                          in: BatchBoard.rotations)
            } else {
                Text("Drag a photo to move it. Pinch to resize, or tap it for size and tilt.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Button("Tidy up", systemImage: "square.grid.2x2") {
                    withAnimation(.snappy) {
                        placements = BatchBoard.tidy(photos, insets: frame.insets, width: width)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    // MARK: Gestures

    private func move(_ photo: Photo, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = placements[photo.id]
                    select(photo)
                }
                guard let start = dragStart else { return }
                update(photo, width: width) {
                    $0.x = start.x + value.translation.width / width
                    $0.y = start.y + value.translation.height / width
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(_ photo: Photo, width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = placements[photo.id]
                    select(photo)
                }
                guard let start = pinchStart else { return }
                update(photo, width: width) { $0.width = start.width * value.magnification }
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func twist(_ photo: Photo, width: CGFloat) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                if twistStart == nil { twistStart = placements[photo.id] }
                guard let start = twistStart else { return }
                update(photo, width: width) { $0.rotation = start.rotation + value.rotation.degrees }
            }
            .onEnded { _ in twistStart = nil }
    }

    // MARK: Changes

    /// Selecting a print also lifts it above the others.
    private func select(_ photo: Photo) {
        selected = photo.id
        let top = placements.values.map(\.z).max() ?? 0
        if placements[photo.id]?.z != top { placements[photo.id]?.z = top + 1 }
    }

    private func update(_ photo: Photo, width: CGFloat, _ change: (inout BatchBoard.Placement) -> Void) {
        guard var place = placements[photo.id] else { return }
        change(&place)
        placements[photo.id] = BatchBoard.clamped(place, photo: photo, insets: frame.insets, boardWidth: width)
    }

    private func nudge(_ photo: Photo, dx: CGFloat = 0, dy: CGFloat = 0, dWidth: CGFloat = 0, width: CGFloat) {
        update(photo, width: width) {
            $0.x += dx
            $0.y += dy
            $0.width += dWidth
        }
    }

    // MARK: The wall, as in the gallery

    @ViewBuilder private var wall: some View {
        switch frame.wall {
        case .light: Color(white: 0.953)
        case .dark: Color(white: 0.07)
        case .desk: DeskMatBackground()
        }
    }

    private var wallScheme: ColorScheme? {
        switch frame.wall {
        case .light: .light
        case .dark: .dark
        case .desk: nil
        }
    }
}
