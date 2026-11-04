import SwiftUI

/// Edge-to-edge view of a pile's photos, letterboxed on black and never cropped at rest.
///
/// - Swipe sideways to page through the pile.
/// - Swipe down to close: the photo follows your finger and the gallery shows through.
/// - Pinch or double-tap to zoom; drag to look around while zoomed; double-tap to fit again.
/// - Tap to hide or show the controls; tap a thumbnail to jump.
/// - The owner can edit a photo or make it the cover from here.
struct FullFrameViewer: View {
    let photos: [Photo]
    var coverID: UUID?
    /// nil for someone else's pile: no editing or cover controls.
    var onEdit: ((Photo) -> Void)?
    var onSetCover: ((Photo) -> Void)?
    var onRemove: ((Photo) -> Void)?
    /// A link that opens this photo in its batch in the app. Share sends this, never the file.
    var shareLink: ((Photo) -> URL)?
    /// For your own batch nobody else can open yet: Share leads to who can see it instead.
    var onShareBatch: (() -> Void)?
    /// Someone else's photo: report it.
    var onReport: ((Photo) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentID: UUID?
    @State private var drag: CGSize = .zero
    @State private var vertical: Bool?          // nil until a drag picks a direction
    @State private var closing = false
    @State private var chromeHidden = false
    @State private var zoomed = false
    @State private var removing: Photo?
    @GestureState private var dragging = false

    private static let closeDistance: CGFloat = 120
    private static let closeVelocity: CGFloat = 800

    init(photos: [Photo], start: Photo, coverID: UUID? = nil,
         onEdit: ((Photo) -> Void)? = nil, onSetCover: ((Photo) -> Void)? = nil, onRemove: ((Photo) -> Void)? = nil,
         shareLink: ((Photo) -> URL)? = nil, onShareBatch: (() -> Void)? = nil, onReport: ((Photo) -> Void)? = nil) {
        self.photos = photos.isEmpty ? [start] : photos
        self.coverID = coverID
        self.onEdit = onEdit
        self.onSetCover = onSetCover
        self.onRemove = onRemove
        self.shareLink = shareLink
        self.onShareBatch = onShareBatch
        self.onReport = onReport
        _currentID = State(initialValue: start.id)
    }

    private var progress: CGFloat { min(1, max(0, drag.height) / 400) }
    private var current: Photo? { photos.first { $0.id == currentID } ?? photos.first }

    var body: some View {
        ZStack {
            Color.black.opacity(closing ? 0 : 1 - progress).ignoresSafeArea()
            pages
                .offset(drag)
                .scaleEffect(1 - 0.25 * progress)
            if !chromeHidden && drag == .zero && !closing { chrome.transition(.opacity) }
        }
        .simultaneousGesture(dismissDrag, including: zoomed ? .subviews : .all)
        .onChange(of: dragging) { _, isDragging in
            // The paging scroll view can take a drag over without onEnded firing.
            if !isDragging, vertical == true, !closing { finishDrag(velocity: 0) }
            if !isDragging { vertical = nil }
        }
        .onChange(of: currentID) { zoomed = false }
        .statusBarHidden(chromeHidden || drag != .zero)
        .presentationBackground(.clear)
        .sensoryFeedback(.selection, trigger: currentID)
    }

    // MARK: Pages

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    ZoomablePhoto(photo: photo, zoomed: photo.id == currentID ? $zoomed : .constant(false)) {
                        withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(photo.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed || drag != .zero)
        .ignoresSafeArea()
    }

    // MARK: Controls

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
                .background(alignment: .top) { scrim(.top) }
            Spacer()
            VStack(spacing: 12) {
                if let caption = current?.caption {
                    Text(caption).titleStyle(.headline, weight: .regular)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                if photos.count > 1 { thumbnails }
                if let current { actionBar(current) }
            }
            .padding(.top, 40)
            .background(alignment: .bottom) { scrim(.bottom) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack {
            Button(action: close) { circleIcon("xmark") }
                .accessibilityLabel("Close")
            Spacer()
            if photos.count > 1, let current, let index = photos.firstIndex(of: current) {
                Text("\(index + 1) of \(photos.count)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
                    .animation(.default, value: index)
            }
            Spacer()
            // Balances the close button so the counter sits in the middle.
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// Every frame in the pile, small, so you can see where you are and jump.
    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(photos) { photo in
                        let selected = photo.id == currentID
                        Button {
                            withAnimation(.snappy) { currentID = photo.id }
                        } label: {
                            PhotoImage(photo: photo)
                                .frame(maxWidth: 72, maxHeight: 46)   // a panorama shouldn't take the whole strip
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(selected ? Color.strewnAccent : .clear, lineWidth: 2)
                                }
                                .opacity(selected ? 1 : 0.55)
                                .scaleEffect(selected ? 1.08 : 1)
                        }
                        .buttonStyle(.plain)
                        .id(photo.id)
                        .accessibilityLabel("Photo \((photos.firstIndex(of: photo) ?? 0) + 1)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentID) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
        }
        .frame(height: 56)
    }

    private func actionBar(_ photo: Photo) -> some View {
        HStack(spacing: 0) {
            if let onEdit {
                actionButton("Edit", systemImage: "slider.horizontal.3") { onEdit(photo) }
            }
            if let onSetCover {
                let isCover = photo.id == coverID
                actionButton(isCover ? "Cover" : "Make cover", systemImage: isCover ? "star.fill" : "star",
                             tint: isCover ? .strewnAccent : .white) { onSetCover(photo) }
                    .disabled(isCover)
                    .sensoryFeedback(.success, trigger: isCover) { _, now in now }
            }
            if let onShareBatch {
                actionButton("Share", systemImage: "square.and.arrow.up", action: onShareBatch)
            } else if let shareLink {
                ShareLink(item: shareLink(photo)) {
                    actionLabel("Share", systemImage: "square.and.arrow.up", tint: .white)
                }
                .frame(maxWidth: .infinity)
            }
            if onRemove != nil {
                actionButton("Remove", systemImage: "rectangle.stack.badge.minus") { removing = photo }
            }
            if let onReport {
                actionButton("Report", systemImage: "flag") { onReport(photo) }
            }
        }
        .confirmationDialog("Remove this photo from the batch?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { photo in
            Button("Remove from batch", role: .destructive) { remove(photo) }
        } message: { _ in
            Text("It stays in your Photos library and on this phone.")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    /// Steps to the neighbouring photo first, so the viewer never shows a photo that's gone;
    /// removing the last one closes it.
    private func remove(_ photo: Photo) {
        guard let onRemove, let i = photos.firstIndex(of: photo) else { return }
        let next = photos.indices.contains(i + 1) ? photos[i + 1] : (i > 0 ? photos[i - 1] : nil)
        if let next { currentID = next.id }
        onRemove(photo)
        if next == nil { close() }
    }

    private func actionButton(_ title: String, systemImage: String, tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, systemImage: systemImage, tint: tint) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func actionLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title3).frame(height: 26)   // icons differ in height; labels shouldn't
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .frame(minWidth: 64, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name).font(.body.weight(.semibold)).frame(width: 40, height: 40)
            .background(.white.opacity(0.14), in: Circle())
    }

    /// A soft dark fade behind the controls, so they read over a bright sky as well as a night.
    private func scrim(_ edge: VerticalEdge) -> some View {
        LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.35), .black.opacity(0)],
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Swipe down to close

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !closing else { return }
                if vertical == nil {
                    vertical = value.translation.height > abs(value.translation.width)
                }
                guard vertical == true else { return }
                drag = CGSize(width: value.translation.width * 0.5, height: value.translation.height)
            }
            .onEnded { value in
                defer { vertical = nil }
                guard vertical == true, !closing else { return }
                finishDrag(velocity: value.velocity.height)
            }
    }

    private func finishDrag(velocity: CGFloat) {
        if drag.height > Self.closeDistance || (velocity > Self.closeVelocity && drag.height > 20) {
            close()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { drag = .zero }
        }
    }

    /// Lets the photo carry on down and fade, then removes the cover without its own slide.
    private func close() {
        guard !closing else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            closing = true
            drag.height = max(drag.height, 0) + 520
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

/// One page: the photo fitted to the screen, with pinch and double-tap zoom.
private struct ZoomablePhoto: View {
    let photo: Photo
    @Binding var zoomed: Bool
    var onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            PhotoImage(photo: photo)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in toggleZoom(at: location, in: geo.size) }
                .onTapGesture(count: 1) { onTap() }
                .gesture(magnify(in: geo.size))
                .gesture(pan(in: geo.size), including: scale > 1 ? .all : .subviews)
        }
        .onChange(of: zoomed) { _, isZoomed in
            if !isZoomed, scale != 1 { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reset() } }
        }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(Self.maxScale, max(0.8, baseScale * value.magnification))
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if scale < 1.05 { reset() } else { baseScale = scale; offset = clamped(offset, in: size); baseOffset = offset }
                }
                zoomed = scale > 1
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = clamped(offset, in: size) }
                baseOffset = offset
            }
    }

    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if scale > 1 {
                reset()
            } else {
                // Zoom toward the tapped point.
                scale = 2.5
                baseScale = scale
                offset = clamped(CGSize(width: (size.width / 2 - location.x) * (scale - 1),
                                        height: (size.height / 2 - location.y) * (scale - 1)), in: size)
                baseOffset = offset
            }
        }
        zoomed = scale > 1
    }

    /// Keeps the zoomed photo covering the screen instead of sliding off into black.
    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let fitted = fittedSize(in: size)
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let maxY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, value.width)), height: min(maxY, max(-maxY, value.height)))
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let aspect = photo.aspectRatio
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
