import SwiftUI

/// Edge-to-edge view of a pile's photos, on a pale fog and never cropped at rest.
///
/// - Swipe sideways to page through the pile.
/// - Swipe down to close: the photo follows your finger and the gallery shows through.
/// - Double-tap to like, with a heart where you tapped.
/// - Pinch to zoom around your fingers; drag to look around while zoomed; double-tap to fit again.
/// - Tap to hide or show the controls; tap a dot to jump.
/// - The latest comments take turns as the photo's caption; like, comment and share sit under it.
/// - Edit, Make cover, Remove and Report are in the menu at the top.
/// The things you can do to a photo that depend on whose it is.
enum PhotoAction { case edit, remove, report, tag, post }

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
    /// The batch, when this photo is yours to post to Instagram or TikTok; nil hides the option.
    var socialBatch: PhotoCollection?
    /// The batch's font, for captions.
    var captionFont: BatchFont?
    /// Likes and comment counts by photo; nil hides the controls (still loading, or unavailable).
    var reactions: [UUID: PhotoReactions]?
    var onLike: ((Photo) -> Void)?
    /// The batch the photos are in, for the comments sheet.
    var commentsBatch: PhotoCollection?
    var canTag = false
    /// Which of the per-photo actions this photo allows, as you page through a batch where some
    /// photos are yours and some a friend's. The actions still have to be given above.
    var allows: (Photo, PhotoAction) -> Bool = { _, _ in true }
    var onOpenUser: ((User) -> Void)?
    var onCommentCount: (Photo, Int) -> Void
    var onTagsChange: (Photo, [PhotoTag]) -> Void

    @State private var commentsPhoto: Photo?
    @State private var tagsPhoto: Photo?
    @State private var socialPhoto: Photo?
    @State private var showTagPins = true
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
    /// Where the top bar ends and the caption and buttons begin, in screen points, so the photo
    /// sits between them instead of under them.
    @State private var topEdge: CGFloat = 0
    @State private var bottomEdge: CGFloat = 0
    /// Where a page ends, which is the screen's bottom edge: pages run under the safe areas, so
    /// measuring the screen from an ordinary view would come up short by the home bar and more.
    @State private var pageBottom: CGFloat = 0
    @State private var removing: Photo?
    @GestureState private var dragging = false

    private static let closeDistance: CGFloat = 120
    private static let closeVelocity: CGFloat = 800

    init(photos: [Photo], start: Photo, coverID: UUID? = nil,
         onEdit: ((Photo) -> Void)? = nil, onSetCover: ((Photo) -> Void)? = nil, onRemove: ((Photo) -> Void)? = nil,
         shareLink: ((Photo) -> URL)? = nil, shareTitle: String = "Batches", onShareBatch: (() -> Void)? = nil,
         socialBatch: PhotoCollection? = nil, onReport: ((Photo) -> Void)? = nil,
         captionFont: BatchFont? = nil, reactions: [UUID: PhotoReactions]? = nil, onLike: ((Photo) -> Void)? = nil,
         commentsBatch: PhotoCollection? = nil, canTag: Bool = false,
         allows: @escaping (Photo, PhotoAction) -> Bool = { _, _ in true }, onOpenUser: ((User) -> Void)? = nil,
         onCommentCount: @escaping (Photo, Int) -> Void = { _, _ in },
         onTagsChange: @escaping (Photo, [PhotoTag]) -> Void = { _, _ in }) {
        self.captionFont = captionFont
        self.reactions = reactions
        self.onLike = onLike
        self.commentsBatch = commentsBatch
        self.canTag = canTag
        self.allows = allows
        self.onOpenUser = onOpenUser
        self.onCommentCount = onCommentCount
        self.onTagsChange = onTagsChange
        self.photos = photos.isEmpty ? [start] : photos
        self.coverID = coverID
        self.onEdit = onEdit
        self.onSetCover = onSetCover
        self.onRemove = onRemove
        self.shareLink = shareLink
        self.shareTitle = shareTitle
        self.onShareBatch = onShareBatch
        self.onReport = onReport
        self.socialBatch = socialBatch
        _currentID = State(initialValue: start.id)
    }

    private var progress: CGFloat { min(1, max(0, drag.height) / 400) }
    private var current: Photo? { photos.first { $0.id == currentID } ?? photos.first }

    var body: some View {
        ZStack {
            Color.viewerFog.opacity(closing ? 0 : 1 - progress).ignoresSafeArea()
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
        .sheet(item: $tagsPhoto) { photo in
            if let commentsBatch {
                PhotoTagsSheet(photo: photo, collection: commentsBatch, canManageTags: canTag(photo),
                               initialTags: reactions?[photo.id]?.tags ?? [],
                               onOpenUser: onOpenUser,
                               onTagsChange: { onTagsChange(photo, $0) })
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $socialPhoto) { photo in
            if let socialBatch {
                SocialShareSheet(collection: socialBatch, photos: [photo], single: photo)
            }
        }
    }

    // MARK: Pages

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    let tags = !chromeHidden && showTagPins && !zoomed ? (reactions?[photo.id]?.tags ?? []) : []
                    ZoomablePhoto(photo: photo, tags: tags, zoomed: photo.id == currentID ? $zoomed : .constant(false),
                                  onOpenUser: onOpenUser,
                                  onDoubleTapLike: likeOnDoubleTap(photo)) {
                        withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() }
                    }
                    // Between the bar and the caption while they show; the whole screen once they're tapped away.
                    .padding(.top, chromeHidden ? 0 : topEdge)
                    .padding(.bottom, chromeHidden ? 0 : max(0, pageBottom - bottomEdge))
                    .containerRelativeFrame([.horizontal, .vertical])
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        // Only the page on screen, at rest: a drag to close moves and shrinks it.
                        if photo.id == currentID, drag == .zero { pageBottom = bottom }
                    }
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

    /// Double-tap only ever likes, never unlikes, so a second burst of taps can't undo it.
    private func likeOnDoubleTap(_ photo: Photo) -> (() -> Void)? {
        guard let onLike, reactions?[photo.id] != nil else { return nil }
        return {
            if reactions?[photo.id]?.likedByMe == false { onLike(photo) }
        }
    }

    // MARK: Controls

    /// Room under the photo for its caption, the latest comment and who's tagged, all at once.
    private static let captionArea: CGFloat = 156

    private var chrome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                topBar
                if photos.count > 1 { dots }
            }
            .padding(.horizontal, 14)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + 8 } action: { topEdge = $0 }
            .padding(.bottom, 28)
            .background(alignment: .top) { scrim(.top) }
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                if let current {
                    // One height whether or not there's a caption or comments, so the photo above
                    // and the buttons below stay put as you swipe from photo to photo.
                    VStack(alignment: .leading, spacing: 10) {
                        if let caption = current.caption {
                            Text(caption).batchTitle(captionFont, .headline, weight: .regular)
                                .lineLimit(1)
                                .padding(.horizontal, 20)
                        }
                        details(current)
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.captionArea, maxHeight: Self.captionArea, alignment: .bottomLeading)
                    // Anything that still doesn't fit is cut off here rather than drawn over the photo.
                    .clipped()
                    actionBar(current)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY - 8 } action: { bottomEdge = $0 }
            .padding(.top, 48)
            .padding(.bottom, 4)
            .background(alignment: .bottom) { scrim(.bottom) }
        }
        .foregroundStyle(.primary)
    }

    private var topBar: some View {
        HStack {
            Button("Close", action: close)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, minHeight: 44, alignment: .leading)
            Spacer()
            if photos.count > 1, let current, let index = photos.firstIndex(of: current) {
                Text("\(index + 1) of \(photos.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: index)
            }
            Spacer()
            if let current, hasMenu(current) {
                Menu { menuItems(current) } label: { circleIcon("ellipsis") }
                    .accessibilityLabel("More")
            } else {
                // Balances the close button so the counter sits in the middle.
                Color.clear.frame(width: 52, height: 44)
            }
        }
    }

    private func hasMenu(_ photo: Photo) -> Bool {
        onSetCover != nil || (onEdit != nil && allows(photo, .edit)) || (onRemove != nil && allows(photo, .remove))
            || (onReport != nil && allows(photo, .report)) || canTag(photo) || (socialBatch != nil && allows(photo, .post))
    }

    private func canTag(_ photo: Photo) -> Bool { canTag && allows(photo, .tag) }

    /// The things you do to a photo now and then, kept away from the ones you tap every time.
    @ViewBuilder
    private func menuItems(_ photo: Photo) -> some View {
        if canTag(photo), commentsBatch != nil {
            Button("Tag people", systemImage: "tag") { tagsPhoto = photo }
        }
        if let onEdit, allows(photo, .edit) {
            Button("Edit", systemImage: "slider.horizontal.3") { onEdit(photo) }
        }
        if socialBatch != nil, allows(photo, .post) {
            Button("Post to Instagram or TikTok", systemImage: "square.and.arrow.up.on.square") { socialPhoto = photo }
        }
        if let onSetCover {
            let isCover = photo.id == coverID
            Button(isCover ? "This is the cover" : "Make cover", systemImage: isCover ? "star.fill" : "star") { onSetCover(photo) }
                .disabled(isCover)
        }
        if onRemove != nil, allows(photo, .remove) {
            Button("Remove from batch", systemImage: "rectangle.stack.badge.minus", role: .destructive) { removing = photo }
        }
        if let onReport, allows(photo, .report) {
            Button("Report photo", systemImage: "flag") { onReport(photo) }
        }
    }

    /// Who added the photo and who's tagged in it, in plain words, then the latest of what people
    /// said about it, one at a time.
    @ViewBuilder
    private func details(_ photo: Photo) -> some View {
        let adder = commentsBatch?.adder(of: photo)
        let tags = reactions?[photo.id]?.tags ?? []
        let comments = latestComments[photo.id] ?? []
        let count = reactions?[photo.id]?.commentCount ?? 0
        if adder != nil || !tags.isEmpty || (count > 0 && !comments.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                if count > 0, !comments.isEmpty {
                    CommentCaption(comments: comments, total: count) {
                        commentsPhoto = photo
                    }
                    .id(photo.id)
                }
                if adder != nil || !tags.isEmpty {
                    HStack(spacing: 10) {
                        if let adder {
                            Text("Added by \(adder.displayName)").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(tags) { tag in
                            Button {
                                if let user = tag.user, let onOpenUser { onOpenUser(user) } else { tagsPhoto = photo }
                            } label: {
                                Text(tag.user.map { "@\($0.handle)" } ?? "Tagged").font(.footnote).foregroundStyle(.secondary)
                                    .underline(color: .secondary.opacity(0.4))
                                    .roomyTapTarget()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    private func loadLatestComments() async {
        guard commentsBatch != nil, let id = currentID, (reactions?[id]?.commentCount ?? 0) > 0,
              let all = try? await model.comments(on: id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { latestComments[id] = Array(all.suffix(5)) }
    }

    private struct CommentsKey: Hashable {
        let photoID: UUID?
        let count: Int
    }

    /// One dot per photo, the current one darker; tap one to jump there.
    private var dots: some View {
        HStack(spacing: 2) {
            ForEach(photos.prefix(24)) { photo in
                let selected = photo.id == currentID
                Button {
                    withAnimation(.snappy) { currentID = photo.id }
                } label: {
                    Circle().fill(selected ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .frame(width: 12, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo \((photos.firstIndex(of: photo) ?? 0) + 1)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: currentID)
    }

    /// The three things you do every time: like, comment, share.
    private func actionBar(_ photo: Photo) -> some View {
        HStack(spacing: 6) {
            if let onLike, let mine = reactions?[photo.id] {
                Button { onLike(photo) } label: {
                    actionLabel(mine.likeCount > 0 ? "\(mine.likeCount)" : nil, systemImage: mine.likedByMe ? "heart.fill" : "heart",
                                tint: mine.likedByMe ? .strewnAccent : .primary)
                }
                .buttonStyle(.plain)
                .symbolEffect(.bounce, value: mine.likedByMe)
                .sensoryFeedback(.impact(weight: .light), trigger: mine.likedByMe)
                .accessibilityLabel(mine.likedByMe ? "Unlike, \(mine.likeCount.counted("like"))" : "Like, \(mine.likeCount.counted("like"))")
            }
            if commentsBatch != nil, let mine = reactions?[photo.id] {
                Button { commentsPhoto = photo } label: {
                    actionLabel(mine.commentCount > 0 ? "\(mine.commentCount)" : nil, systemImage: "bubble.left", tint: .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Comments, \(mine.commentCount)")
                if canTag(photo) || !mine.tags.isEmpty {
                    Button {
                        tagsPhoto = photo
                    } label: {
                        actionLabel(mine.tags.isEmpty ? nil : "\(mine.tags.count)",
                                    systemImage: mine.tags.isEmpty ? "tag" : "tag.fill",
                                    tint: .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(canTag(photo) ? "Tag people, \(mine.tags.count)" : "Tagged people, \(mine.tags.count)")
                }
                if mine.tags.contains(where: \.hasPosition) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showTagPins.toggle() }
                    } label: {
                        Image(systemName: showTagPins ? "eye" : "eye.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showTagPins ? "Hide tag pins" : "Show tag pins")
                }
            }
            Spacer(minLength: 0)
            if let onShareBatch {
                Button(action: onShareBatch) { actionLabel(nil, systemImage: "square.and.arrow.up", tint: .primary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
            } else if let shareLink {
                LinkShareButton(url: shareLink(photo), title: shareTitle, photo: photo) {
                    actionLabel(nil, systemImage: "square.and.arrow.up", tint: .primary)
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
            Image(systemName: systemImage).font(.title3.weight(.light)).frame(height: 28)   // icons differ in height
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
        Image(systemName: name).font(.body).foregroundStyle(.secondary).frame(width: 52, height: 44, alignment: .trailing)
    }

    /// A soft fog behind the controls, so they still read where a zoomed photo runs under them.
    private func scrim(_ edge: VerticalEdge) -> some View {
        LinearGradient(colors: [Color.viewerFog.opacity(0.9), Color.viewerFog.opacity(0.5), Color.viewerFog.opacity(0)],
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
                guard !zoomed else {
                    // A pinch began after the drag did: hand the photo back to the pinch.
                    if drag != .zero { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero } }
                    return
                }
                if vertical == nil {
                    vertical = value.translation.height > abs(value.translation.width)
                }
                guard vertical == true else { return }
                drag = CGSize(width: value.translation.width * 0.5, height: value.translation.height)
            }
            .onEnded { value in
                defer { vertical = nil }
                guard vertical == true, !closing, !zoomed else { return }
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

/// One page: the photo fitted to the screen, plus pinned tags.
///
/// Zoom follows your fingers: the spot you pinch stays under them, it gives a little past
/// the limits and springs back, and a flick while zoomed glides to a stop. Double-tap likes
/// (with a heart where you tapped) or, when zoomed in, fits the photo again.
private struct ZoomablePhoto: View {
    let photo: Photo
    var tags: [PhotoTag] = []
    @Binding var zoomed: Bool
    var onOpenUser: ((User) -> Void)?
    /// Double-tap at fit. nil makes double-tap zoom in instead.
    var onDoubleTapLike: (() -> Void)?
    var onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Where the current pinch or pan began; nil between gestures.
    @State private var pinchStart: (scale: CGFloat, offset: CGSize, anchor: CGPoint)?
    @State private var panStart: CGSize?
    @State private var hearts: [HeartBurst.Model] = []
    @State private var bumpedLimit = 0
    @State private var likeTaps = 0

    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5
    private static let settle = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedSize(in: geo.size)
            PhotoImage(photo: photo)
                .overlay {
                    ZStack {
                        ForEach(tags) { tag in
                            if let x = tag.x, let y = tag.y {
                                PhotoTagPin(handle: tag.user?.handle ?? "tagged",
                                            point: CGPoint(x: x, y: y),
                                            in: fitted) {
                                    if let user = tag.user { onOpenUser?(user) }
                                }
                            }
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                }
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay {
                    ZStack {
                        ForEach(hearts) { heart in
                            HeartBurst(model: heart) { hearts.removeAll { $0.id == heart.id } }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in doubleTap(at: location, in: geo.size) }
                .onTapGesture(count: 1) { onTap() }
                .gesture(magnify(in: geo.size))
                .gesture(pan(in: geo.size), including: scale > 1 ? .all : .subviews)
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: bumpedLimit)
        .sensoryFeedback(.impact(weight: .medium), trigger: likeTaps)
        .onChange(of: zoomed) { _, isZoomed in
            if !isZoomed, scale != 1, pinchStart == nil { withAnimation(Self.settle) { reset() } }
        }
    }

    // MARK: Gestures

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchStart == nil {
                    let anchor = CGPoint(x: value.startLocation.x - size.width / 2,
                                         y: value.startLocation.y - size.height / 2)
                    pinchStart = (scale, offset, anchor)
                    zoomed = true   // hides tag pins and stops paging / swipe-to-close straight away
                }
                guard let start = pinchStart else { return }
                let newScale = Self.rubberBandScale(start.scale * value.magnification)
                setWithoutAnimation {
                    scale = newScale
                    offset = Self.keeping(start.anchor, fixedFrom: start.scale, start.offset, to: newScale)
                }
            }
            .onEnded { _ in
                guard let start = pinchStart else { return }
                pinchStart = nil
                let overshot = scale < 1 || scale > Self.maxScale
                withAnimation(Self.settle) {
                    if scale <= 1.02 {
                        reset()
                    } else {
                        let target = min(scale, Self.maxScale)
                        // Pull back from an over-zoom around the same spot, then keep the photo on screen.
                        let anchored = Self.keeping(start.anchor, fixedFrom: scale, offset, to: target)
                        scale = target
                        offset = clamped(anchored, in: size)
                    }
                }
                if overshot { bumpedLimit += 1 }
                zoomed = scale > 1
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard pinchStart == nil else { return }
                let start = panStart ?? offset
                if panStart == nil { panStart = start }
                let raw = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                setWithoutAnimation { offset = rubberBanded(raw, in: size) }
            }
            .onEnded { value in
                guard let start = panStart else { return }
                panStart = nil
                // Carry the flick on a little, then come to rest inside the edges.
                let glide = CGSize(width: start.width + value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.6,
                                   height: start.height + value.translation.height + (value.predictedEndTranslation.height - value.translation.height) * 0.6)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { offset = clamped(glide, in: size) }
            }
    }

    private func doubleTap(at location: CGPoint, in size: CGSize) {
        if scale > 1 {
            withAnimation(Self.settle) { reset() }
            zoomed = false
        } else if let onDoubleTapLike {
            hearts.append(.init(point: location))
            likeTaps += 1
            onDoubleTapLike()
        } else {
            let anchor = CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
            withAnimation(Self.settle) {
                scale = Self.doubleTapScale
                offset = clamped(Self.keeping(anchor, fixedFrom: 1, .zero, to: scale), in: size)
            }
            zoomed = true
        }
    }

    // MARK: Geometry

    /// The offset that keeps `anchor` (a point relative to the page's centre) under the fingers
    /// while the scale goes from `fromScale` to `toScale`.
    private static func keeping(_ anchor: CGPoint, fixedFrom fromScale: CGFloat, _ fromOffset: CGSize, to toScale: CGFloat) -> CGSize {
        let ratio = toScale / fromScale
        return CGSize(width: anchor.x - ratio * (anchor.x - fromOffset.width),
                      height: anchor.y - ratio * (anchor.y - fromOffset.height))
    }

    /// Past the limits the photo still moves, but less and less, like a scroll view's edge.
    private static func rubberBand(_ excess: CGFloat, limit: CGFloat) -> CGFloat {
        (1 - 1 / (excess * 0.55 / limit + 1)) * limit
    }

    private static func rubberBandScale(_ raw: CGFloat) -> CGFloat {
        if raw < 1 { return 1 - rubberBand(1 - raw, limit: 0.45) }
        if raw > maxScale { return maxScale + rubberBand(raw - maxScale, limit: maxScale * 0.35) }
        return raw
    }

    private func bounds(in size: CGSize) -> CGSize {
        let fitted = fittedSize(in: size)
        return CGSize(width: max(0, (fitted.width * scale - size.width) / 2),
                      height: max(0, (fitted.height * scale - size.height) / 2))
    }

    /// Keeps the zoomed photo covering the screen instead of sliding off into black.
    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let b = bounds(in: size)
        return CGSize(width: min(b.width, max(-b.width, value.width)), height: min(b.height, max(-b.height, value.height)))
    }

    private func rubberBanded(_ value: CGSize, in size: CGSize) -> CGSize {
        let b = bounds(in: size)
        func axis(_ v: CGFloat, _ limit: CGFloat, _ dimension: CGFloat) -> CGFloat {
            if v > limit { return limit + Self.rubberBand(v - limit, limit: dimension * 0.5) }
            if v < -limit { return -limit - Self.rubberBand(-limit - v, limit: dimension * 0.5) }
            return v
        }
        return CGSize(width: axis(value.width, b.width, size.width), height: axis(value.height, b.height, size.height))
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let aspect = photo.aspectRatio
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    private func reset() {
        scale = 1
        offset = .zero
    }

    /// Follows the fingers exactly, without an animation from elsewhere smoothing it into lag.
    private func setWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// The heart that pops where you double-tapped: it springs up, wobbles, then floats off and fades.
private struct HeartBurst: View {
    struct Model: Identifiable {
        let id = UUID()
        let point: CGPoint
        let tilt = Double.random(in: -14...14)
    }

    let model: Model
    var onFinish: () -> Void
    @State private var play = false

    private struct Frame {
        var scale: CGFloat = 0.2
        var opacity: Double = 0
        var rise: CGFloat = 0
    }

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 96))
            .foregroundStyle(Color.strewnAccent.gradient)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .rotationEffect(.degrees(model.tilt))
            .keyframeAnimator(initialValue: Frame(), trigger: play) { content, frame in
                content
                    .scaleEffect(frame.scale)
                    .opacity(frame.opacity)
                    .offset(y: frame.rise)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.2, duration: 0.18, spring: .snappy)
                    SpringKeyframe(0.95, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.12)
                    LinearKeyframe(1.0, duration: 0.3)
                    CubicKeyframe(0.7, duration: 0.3)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.64)
                    CubicKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.rise) {
                    LinearKeyframe(0, duration: 0.72)
                    CubicKeyframe(-90, duration: 0.3)
                }
            }
            .position(model.point)
            .task {
                play = true
                try? await Task.sleep(for: .milliseconds(1100))
                onFinish()
            }
    }
}

/// The latest comments on a photo, taking turns as its caption: each rises in from a soft blur
/// while the last one drifts up and out. Small marks above count down to the next.
/// VoiceOver gets the first one, held still, with the rest a tap away.
private struct CommentCaption: View {
    let comments: [PhotoComment]
    let total: Int
    var onOpen: () -> Void

    @State private var index = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hold: Duration = .seconds(1.6)
    private var rotates: Bool { comments.count > 1 && !voiceOver }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                if rotates { marks }
                ZStack(alignment: .topLeading) {
                    let comment = comments[min(index, comments.count - 1)]
                    VStack(alignment: .leading, spacing: 6) {
                        MentionText("\u{201C}\(comment.body)\u{201D}")
                            .font(.system(.title3, design: .serif).italic())
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(byline(comment)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .id(comment.id)
                    .transition(.asymmetric(insertion: .modifier(active: Drift(y: reduceMotion ? 0 : 10, blur: reduceMotion ? 0 : 4, opacity: 0),
                                                                  identity: Drift()),
                                            removal: .modifier(active: Drift(y: reduceMotion ? 0 : -10, blur: reduceMotion ? 0 : 4, opacity: 0),
                                                               identity: Drift())))
                }
                .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(total > 1 ? "Opens all \(total) comments" : "Opens the comments")
        .task(id: comments.map(\.id)) {
            index = 0
            guard rotates else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.hold)
                if Task.isCancelled { break }
                withAnimation(.smooth(duration: 0.55)) { index = (index + 1) % comments.count }
            }
        }
    }

    private func byline(_ comment: PhotoComment) -> String {
        let name = comment.author?.displayName ?? "Someone"
        return total > comments.count ? "\(name), one of \(total) comments" : name
    }

    /// One mark per comment: the ones shown are filled, the current one fills as it waits.
    private var marks: some View {
        HStack(spacing: 4) {
            ForEach(comments.indices, id: \.self) { i in
                Mark(phase: i < index ? .done : i == index ? .running : .waiting, duration: 1.6)
            }
        }
        .accessibilityHidden(true)
    }

    private struct Mark: View {
        enum Phase { case done, running, waiting }
        let phase: Phase
        let duration: Double
        @State private var fill: CGFloat = 0

        var body: some View {
            Capsule().fill(Color.secondary.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary).scaleEffect(x: fill, anchor: .leading)
                }
                .frame(width: 14, height: 2)
                .clipShape(Capsule())
                .onAppear(perform: update)
                .onChange(of: phase) { update() }
        }

        private func update() {
            switch phase {
            case .done: fill = 1
            case .waiting: fill = 0
            case .running:
                var reset = Transaction(); reset.disablesAnimations = true
                withTransaction(reset) { fill = 0 }
                withAnimation(.linear(duration: duration)) { fill = 1 }
            }
        }
    }
}

/// Moves, blurs and fades a caption in or out.
private struct Drift: ViewModifier {
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1
    func body(content: Content) -> some View {
        content.offset(y: y).blur(radius: blur).opacity(opacity)
    }
}
