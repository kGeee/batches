import SwiftUI

/// Edge-to-edge view of a pile's photos, letterboxed on black and never cropped at rest.
///
/// - Swipe sideways to page through the pile.
/// - Swipe down to close: the photo follows your finger and the gallery shows through.
/// - Pinch or double-tap to zoom; drag to look around while zoomed; double-tap to fit again.
/// - Tap to hide or show the controls; tap a thumbnail to jump.
/// - Like, comment and share sit under the photo, with the latest comments above them.
/// - Edit, Make cover, Remove and Report are in the menu at the top.
struct FullFrameViewer: View {
    let photos: [Photo]
    var coverID: UUID?
    /// nil for someone else's pile: no editing or cover controls.
    var onEdit: ((Photo) -> Void)?
    var onSetCover: ((Photo) -> Void)?
    var onRemove: ((Photo) -> Void)?
    /// A link that opens this photo in its batch in the app. Share sends this, never the file.
    var shareLink: ((Photo) -> URL)?
    /// The batch's title, shown in the link's preview.
    var shareTitle = "Batches"
    /// For your own batch nobody else can open yet: Share leads to who can see it instead.
    var onShareBatch: (() -> Void)?
    /// Someone else's photo: report it.
    var onReport: ((Photo) -> Void)?
    /// The batch's font, for captions.
    var captionFont: BatchFont?
    /// Likes and comment counts by photo; nil hides the controls (still loading, or unavailable).
    var reactions: [UUID: PhotoReactions]?
    var onLike: ((Photo) -> Void)?
    /// The batch the photos are in, for the comments sheet.
    var commentsBatch: PhotoCollection?
    var onCommentCount: (Photo, Int) -> Void

    @State private var commentsPhoto: Photo?
    /// The latest comments on each photo looked at, shown under it.
    @State private var latestComments: [UUID: [PhotoComment]] = [:]

    @Environment(AppModel.self) private var model
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
         shareLink: ((Photo) -> URL)? = nil, shareTitle: String = "Batches", onShareBatch: (() -> Void)? = nil, onReport: ((Photo) -> Void)? = nil,
         captionFont: BatchFont? = nil, reactions: [UUID: PhotoReactions]? = nil, onLike: ((Photo) -> Void)? = nil,
         commentsBatch: PhotoCollection? = nil, onCommentCount: @escaping (Photo, Int) -> Void = { _, _ in }) {
        self.captionFont = captionFont
        self.reactions = reactions
        self.onLike = onLike
        self.commentsBatch = commentsBatch
        self.onCommentCount = onCommentCount
        self.photos = photos.isEmpty ? [start] : photos
        self.coverID = coverID
        self.onEdit = onEdit
        self.onSetCover = onSetCover
        self.onRemove = onRemove
        self.shareLink = shareLink
        self.shareTitle = shareTitle
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
        .task(id: CommentsKey(photoID: currentID, count: currentID.flatMap { reactions?[$0]?.commentCount } ?? 0)) {
            await loadLatestComments()
        }
        .confirmationDialog("Remove this photo from the batch?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { photo in
            Button("Remove from batch", role: .destructive) { remove(photo) }
        } message: { _ in
            Text("It stays in your Photos library and on this phone.")
        }
        .sheet(item: $commentsPhoto) { photo in
            if let commentsBatch {
                PhotoCommentsSheet(photo: photo, collection: commentsBatch) { onCommentCount(photo, $0) }
                    .presentationDetents([.medium, .large])
            }
        }
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
            VStack(alignment: .leading, spacing: 14) {
                if let caption = current?.caption {
                    Text(caption).batchTitle(captionFont, .headline, weight: .regular)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                }
                if let current {
                    details(current)
                    actionBar(current)
                }
                if photos.count > 1 { thumbnails }
            }
            .padding(.top, 48)
            .padding(.bottom, 4)
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
            if let current, hasMenu {
                Menu { menuItems(current) } label: { circleIcon("ellipsis") }
                    .accessibilityLabel("More")
            } else {
                // Balances the close button so the counter sits in the middle.
                Color.clear.frame(width: 40, height: 40)
            }
        }
    }

    private var hasMenu: Bool { onEdit != nil || onSetCover != nil || onRemove != nil || onReport != nil }

    /// The things you do to a photo now and then, kept away from the ones you tap every time.
    @ViewBuilder
    private func menuItems(_ photo: Photo) -> some View {
        if let onEdit {
            Button("Edit", systemImage: "slider.horizontal.3") { onEdit(photo) }
        }
        if let onSetCover {
            let isCover = photo.id == coverID
            Button(isCover ? "This is the cover" : "Make cover", systemImage: isCover ? "star.fill" : "star") { onSetCover(photo) }
                .disabled(isCover)
        }
        if onRemove != nil {
            Button("Remove from batch", systemImage: "rectangle.stack.badge.minus", role: .destructive) { removing = photo }
        }
        if let onReport {
            Button("Report photo", systemImage: "flag") { onReport(photo) }
        }
    }

    /// Who added the photo, and the latest of what people said about it.
    @ViewBuilder
    private func details(_ photo: Photo) -> some View {
        let adder = commentsBatch?.adder(of: photo)
        let comments = latestComments[photo.id] ?? []
        let count = reactions?[photo.id]?.commentCount ?? 0
        if adder != nil || (count > 0 && !comments.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                if let adder {
                    HStack(spacing: 8) {
                        AvatarView(user: adder, size: 24)
                        Text("Added by \(adder.displayName)").font(.subheadline.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                }
                if count > 0, !comments.isEmpty {
                    Button { commentsPhoto = photo } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(comments) { comment in
                                (Text(comment.author?.displayName ?? "Someone").fontWeight(.semibold) + Text("  \(comment.body)"))
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            if count > comments.count {
                                Text("View all \(count) comments").font(.footnote).foregroundStyle(.white.opacity(0.6))
                                    .padding(.top, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the comments")
                }
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    private func loadLatestComments() async {
        guard commentsBatch != nil, let id = currentID, (reactions?[id]?.commentCount ?? 0) > 0,
              let all = try? await model.comments(on: id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { latestComments[id] = Array(all.suffix(2)) }
    }

    private struct CommentsKey: Hashable {
        let photoID: UUID?
        let count: Int
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

    /// The three things you do every time: like, comment, share.
    private func actionBar(_ photo: Photo) -> some View {
        HStack(spacing: 6) {
            if let onLike, let mine = reactions?[photo.id] {
                Button { onLike(photo) } label: {
                    actionLabel(mine.likeCount > 0 ? "\(mine.likeCount)" : nil, systemImage: mine.likedByMe ? "heart.fill" : "heart",
                                tint: mine.likedByMe ? .strewnAccent : .white)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: mine.likedByMe)
                .accessibilityLabel(mine.likedByMe ? "Unlike, \(mine.likeCount.counted("like"))" : "Like, \(mine.likeCount.counted("like"))")
            }
            if commentsBatch != nil, let mine = reactions?[photo.id] {
                Button { commentsPhoto = photo } label: {
                    actionLabel(mine.commentCount > 0 ? "\(mine.commentCount)" : nil, systemImage: "bubble.left", tint: .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Comments, \(mine.commentCount)")
            }
            Spacer(minLength: 0)
            if let onShareBatch {
                Button(action: onShareBatch) { actionLabel(nil, systemImage: "square.and.arrow.up", tint: .white) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
            } else if let shareLink {
                LinkShareButton(url: shareLink(photo), title: shareTitle, photo: photo) {
                    actionLabel(nil, systemImage: "square.and.arrow.up", tint: .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 10)
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

    private func actionLabel(_ count: String?, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.title2).frame(height: 28)   // icons differ in height
            if let count {
                Text(count).font(.body.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(minWidth: 48, minHeight: 48)
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
