import PhotosUI
import SwiftUI

/// A pile spread out into a scrolling gallery. Full frame is the rule: in the single-column
/// layout every photo is sized so the whole framed print fits in the visible height, in two
/// columns photos keep their shape in a masonry layout, and a film-framed pile becomes one
/// continuous roll you swipe along. Nothing is cropped unless the owner crops it in the editor.
/// Besides the back button, pulling down from the top (or dragging the header) shrinks the
/// photos toward the desk, and letting go past the threshold puts them back on the pile.
struct GalleryView: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let isOwner: Bool
    /// Tapping the owner's name opens their profile, where the caller can push one.
    var onOpenOwner: ((User) -> Void)? = nil
    /// Opened from a link to one photo: show it as soon as the batch is up.
    var startPhotoID: UUID? = nil
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.tiltedPiles) private var tiltedPiles
    @State private var showFrames = false
    @State private var showShare = false
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var showReorder = false
    @State private var showFont = false
    @State private var showDescription = false
    /// Likes and comment counts by photo; nil while loading, or when they can't be loaded.
    @State private var reactions: [UUID: PhotoReactions]?
    @State private var commentsPhoto: Photo?
    @State private var arrangingBoard = false
    @State private var reporting: ReportTarget?
    @State private var confirmingBlock = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var removing: Photo?
    @State private var viewerPhoto: Photo?
    @State private var editingPhoto: Photo?
    @State private var appeared = false
    @State private var pull: CGFloat = 0        // overscroll past the top while pulling
    @State private var headerPull: CGFloat = 0  // drag on the header, works at any scroll position
    /// The big title at the top has scrolled away, so the header shows it instead.
    @State private var titleScrolledAway = false

    private var frame: FrameStyle { collection.frame }
    private var pullDistance: CGFloat { max(pull, headerPull) }
    private var pullProgress: CGFloat { min(1, pullDistance / PullToDismiss.fullPull) }

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height - 120   // header and caption row
            ZStack {
                collection.backdrop.view.ignoresSafeArea().opacity(appeared ? 1 - 0.6 * pullProgress : 0)
                VStack(spacing: 0) {
                    header.opacity(appeared ? 1 - 0.8 * pullProgress : 0)
                    ScrollView {
                        intro.opacity(appeared ? 1 : 0)
                        Group {
                            if frame.kind == .filmStrip {
                                FilmRollView(collection: collection, namespace: namespace,
                                             availableHeight: geo.size.height - 60, width: geo.size.width,
                                             onView: { viewerPhoto = $0 })
                            } else if collection.showsBoard {
                                boardCanvas(width: geo.size.width)
                            } else if frame.layout == .single {
                                LazyVStack(spacing: 22) { photoCells(maxPhotoHeight: available) }
                                    .padding(.horizontal, 12)
                            } else {
                                MasonryLayout(columns: 2, spacing: 10) { photoCells(maxPhotoHeight: .infinity) }
                                    .padding(.horizontal, 12)
                            }
                        }
                        .padding(.bottom, 40)
                    }
                    .scrollIndicators(.hidden)
                    .modifier(TitleScrollTracker(scrolledAway: $titleScrolledAway))
                    .pullDownToDismiss(distance: $pull, onDismiss: close)
                    // shrink toward the desk as you pull; render-only, so layout and scrolling are untouched
                    .scaleEffect(1 - 0.22 * pullProgress, anchor: .top)
                    .offset(y: headerPull * 0.9)
                }
            }
        }
        // A light wall is light in dark mode too, and a dark wall dark in light mode, so the
        // text and controls on it follow the wall, not the system. The desk follows the system.
        .environment(\.colorScheme, collection.backdrop.scheme ?? systemScheme)
        .tint(collection.backdrop.neutralControls ? Color.primary : Color.strewnAccent)
        .task(id: collection.photos.map(\.id)) { reactions = await model.reactions(for: collection.photos) }
        .onAppear { withAnimation(.easeOut(duration: 0.35).delay(0.1)) { appeared = true } }
        .task {
            guard let startPhotoID, let photo = collection.photos.first(where: { $0.id == startPhotoID }) else { return }
            try? await Task.sleep(for: .milliseconds(450))
            viewerPhoto = photo
        }
        .sensoryFeedback(.selection, trigger: collection.coverPhotoID)
        .sensoryFeedback(.impact(weight: .light), trigger: pullDistance > PullToDismiss.threshold) { _, past in past }
        .accessibilityAction(.escape, close)   // VoiceOver's two-finger scrub
        .sheet(isPresented: $showFrames) {
            FramePickerSheet(frame: Binding(get: { collection.frame }, set: { model.setFrame($0, for: collection.id) }),
                             boardOn: Binding(get: { collection.board?.isOn == true }, set: { model.setBoardOn($0, for: collection.id) }),
                             background: Binding(get: { collection.backdrop }, set: { model.setBackground($0, for: collection.id) }))
                .presentationDetents([.height(430)])
        }
        .sheet(isPresented: $showShare) { SharePileSheet(collectionID: collection.id) }
        .sheet(isPresented: $showReorder) { ReorderPhotosSheet(collectionID: collection.id) }
        .sheet(isPresented: $showFont) {
            BatchFontSheet(title: collection.title, current: collection.font) { model.setFont($0, for: collection.id) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDescription) {
            BatchDescriptionSheet(current: collection.description) { model.setDescription($0, for: collection.id) }
                .presentationDetents([.medium])
        }
        .sheet(item: $commentsPhoto) { photo in
            PhotoCommentsSheet(photo: photo, collection: collection) { setCommentCount($0, for: photo) }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $arrangingBoard) {
            BoardEditorView(collection: collection) { model.setBoard($0, for: collection.id) }
        }
        .sheet(isPresented: $renaming) {
            PaperTextPrompt(title: "Rename batch", placeholder: "Name", initial: collection.title) { model.rename(collection.id, to: $0) }
                .presentationDetents([.height(200)])
                .environment(\.colorScheme, systemScheme)
        }
        .fullScreenCover(item: $viewerPhoto) { photo in
            // Just the photo you tapped: no paging sideways through the rest of the pile.
            FullFrameViewer(photos: [photo], start: photo, coverID: collection.coverPhotoID,
                            onEdit: canEdit(photo) ? { edit($0) } : nil,
                            onSetCover: isOwner ? { model.setCover($0, in: collection.id) } : nil,
                            onRemove: canRemove(photo) ? { remove($0) } : nil,
                            shareLink: { AppModel.link(to: collection, photo: $0) }, shareTitle: collection.title,
                            onShareBatch: isOwner && !collection.isShared ? { openShareSettings() } : nil,
                            onReport: canReport(photo) ? { report($0) } : nil,
                            captionFont: collection.font,
                            reactions: reactions,
                            onLike: reactions == nil ? nil : { like($0) },
                            commentsBatch: reactions == nil ? nil : collection,
                            onCommentCount: { setCommentCount($1, for: $0) })
        }
        .sheet(item: $reporting) { target in
            ReportSheet(subject: target.subject, report: target.report, owner: target.owner)
        }
        .confirmationDialog("Block @\(collection.owner?.handle ?? "")?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let owner = collection.owner else { return }
                Task { await model.block(owner) }
                close()
            }
        } message: {
            Text("Neither of you will see the other's batches, you'll stop following each other, and batches shared between you stop being shared. They aren't told.")
        }
        .confirmationDialog("Remove this photo from the batch?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { photo in
            Button("Remove from batch", role: .destructive) {
                withAnimation(.snappy) { remove(photo) }
            }
        } message: { photo in
            if let adder = collection.adder(of: photo), adder.id != model.me?.id {
                Text("It leaves the batch for everyone. \(adder.displayName) still has the original.")
            } else {
                Text("It stays in your Photos library and on this phone.")
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                let photos = await PhotoImport.photos(from: items, collectionID: collection.id)
                if isOwner {
                    withAnimation(.snappy) { model.addPhotos(photos, to: collection.id) }
                } else {
                    await model.contribute(photos, to: collection.id)
                }
                picked = []
                importing = false
            }
        }
        .fullScreenCover(item: $editingPhoto) { photo in
            EditorView(
                model: EditorModel(sourceURL: photo.editSourceURL, recipe: photo.edit),
                pileCount: collection.photos.count,
                onCancel: { editingPhoto = nil },
                onDone: { recipe in
                    await model.saveEdit(recipe, photoID: photo.id, collectionID: collection.id)
                    editingPhoto = nil
                },
                onPasteToPile: { recipe in
                    await model.applyEdits(recipe, toPile: collection.id, except: photo.id)
                })
        }
    }

    @ViewBuilder
    private func photoCells(maxPhotoHeight: CGFloat) -> some View {
        let stackIDs = Set(collection.pileStack().map(\.id))
        ForEach(Array(collection.photos.enumerated()), id: \.element.id) { index, photo in
            let inPile = stackIDs.contains(photo.id)
            let angle = inPile ? PileLayout.placement(for: photo, isTop: photo.id == collection.cover?.id, tilted: tiltedPiles).angle : .zero
            VStack(spacing: 8) {
                PhotoImage(photo: photo)
                    // Fit inside the visible height minus the frame, so tall portraits are
                    // shown whole instead of running off screen.
                    .frame(maxHeight: maxPhotoHeight - frame.insets.top - frame.insets.bottom)
                    .photoFrame(frame, caption: photo.caption, frameNumber: index + 1, captionFont: collection.font)
                    .matchedGeometryEffect(id: photo.id, in: namespace)
                    .transition(inPile ? .pileRotation(angle) : .opacity)
                    .onTapGesture { viewerPhoto = photo }
                    .contextMenu { photoMenu(photo) }
                // Two columns are a contact sheet: the prints alone read better.
                if frame.layout == .single {
                    PhotoMetaRow(collection: collection, photo: photo, index: index, reactions: reactions?[photo.id])
                        .opacity(appeared ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The owner's freehand board. Same prints and menus as the other layouts, in the places the
    /// owner put them; a photo with no place yet (a friend just added it) goes below the rest.
    private func boardCanvas(width: CGFloat) -> some View {
        let placements = BatchBoard.resolved(collection.board, photos: collection.photos, insets: frame.insets, width: width)
        let stackIDs = Set(collection.pileStack().map(\.id))
        return ZStack {
            ForEach(Array(collection.photos.enumerated()), id: \.element.id) { index, photo in
                if let place = placements[photo.id] {
                    let inPile = stackIDs.contains(photo.id)
                    let angle = inPile ? PileLayout.placement(for: photo, isTop: photo.id == collection.cover?.id, tilted: tiltedPiles).angle : .zero
                    PhotoImage(photo: photo)
                        .frame(width: BatchBoard.imageWidth(place, insets: frame.insets, boardWidth: width))
                        .photoFrame(frame, caption: photo.caption, frameNumber: index + 1, captionFont: collection.font)
                        .matchedGeometryEffect(id: photo.id, in: namespace)
                        .transition(inPile ? .pileRotation(angle) : .opacity)
                        .rotationEffect(place.angle)
                        .onTapGesture { viewerPhoto = photo }
                        .contextMenu { photoMenu(photo) }
                        .position(x: place.x * width, y: place.y * width)
                        .zIndex(Double(place.z))
                }
            }
        }
        .frame(width: width, height: BatchBoard.height(of: collection.photos, placements: placements, insets: frame.insets, width: width))
    }

    @ViewBuilder
    private func photoMenu(_ photo: Photo) -> some View {
        Button("View", systemImage: "arrow.up.left.and.arrow.down.right") { viewerPhoto = photo }
        if let mine = reactions?[photo.id] {
            Button(mine.likedByMe ? "Unlike" : "Like", systemImage: mine.likedByMe ? "heart.slash" : "heart") { like(photo) }
            Button("Comments", systemImage: "bubble.left") { commentsPhoto = photo }
        }
        if canEdit(photo) {
            Button("Edit", systemImage: "slider.horizontal.3") { editingPhoto = photo }
        }
        if isOwner {
            Button("Make cover", systemImage: "star") { model.setCover(photo, in: collection.id) }
                .disabled(photo.id == collection.coverPhotoID)
        }
        if isOwner && !collection.isShared {
            // Nobody else can open this batch yet, so a link would lead nowhere.
            Button("Share", systemImage: "square.and.arrow.up") { showShare = true }
        } else {
            LinkShareButton(url: AppModel.link(to: collection, photo: photo), title: collection.title, photo: photo) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if canRemove(photo) {
            Button("Remove from batch", systemImage: "rectangle.stack.badge.minus", role: .destructive) { removing = photo }
        }
        if canReport(photo) {
            Button("Report photo", systemImage: "flag") { report(photo) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) { headerIcon("chevron.left") }
                .accessibilityLabel("Back to the desk")
            VStack(alignment: .leading, spacing: 1) {
                Text(collection.title).batchTitle(collection.font, .headline).lineLimit(1)
                Text(subtitle).metaStyle().lineLimit(1)
            }
            // The big title says it at the top; the header takes over once that scrolls away.
            .opacity(titleScrolledAway ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: titleScrolledAway)
            Spacer(minLength: 4)
            // Icon-only, so the title keeps the room.
            if canAdd {
                PhotosPicker(selection: $picked, maxSelectionCount: 60, matching: .images,
                             preferredItemEncoding: .current, photoLibrary: .shared()) {
                    if importing {
                        ProgressView().frame(width: 38, height: 38)
                    } else {
                        headerIcon("plus")
                    }
                }
                .disabled(importing)
                .accessibilityLabel("Add photos")
            }
            if isOwner {
                Button { showShare = true } label: {
                    headerIcon(collection.isShared ? collection.visibility.symbol : "square.and.arrow.up")
                }
                .accessibilityLabel("Share, \(collection.visibility.title)")
                Button { showFrames = true } label: { headerIcon("square.inset.filled") }
                    .accessibilityLabel("Frames")
                Menu {
                    Button("Rename", systemImage: "pencil", action: startRename)
                    Button("Description", systemImage: "text.alignleft") { showDescription = true }
                    Button("Font", systemImage: "textformat") { showFont = true }
                    if frame.kind != .filmStrip {
                        Button("Arrange board", systemImage: "hand.draw") { arrangingBoard = true }
                            .disabled(collection.photos.isEmpty)
                    }
                    Button("Reorder photos", systemImage: "arrow.up.arrow.down") { showReorder = true }
                        .disabled(collection.photos.count < 2)
                } label: { headerIcon("ellipsis") }
                .accessibilityLabel("More")
            } else if let owner = collection.owner {
                Menu {
                    Button("Report batch", systemImage: "flag") {
                        reporting = ReportTarget(subject: "this batch", report: Report(collectionID: collection.id, reason: .other), owner: owner)
                    }
                    Button("Block @\(owner.handle)", systemImage: "hand.raised", role: .destructive) { confirmingBlock = true }
                } label: { headerIcon("ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 2)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { headerPull = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > PullToDismiss.threshold || value.predictedEndTranslation.height > PullToDismiss.threshold * 3 {
                        close()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { headerPull = 0 }
                    }
                }
        )
    }

    /// The pile's title page: what it is, where and when, and whose.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(collection.title).batchTitle(collection.font, .largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                // Your own pile's title is also the quickest way to rename it.
                .onTapGesture { if isOwner { startRename() } }
                .accessibilityAddTraits(isOwner ? .isButton : [])
                .accessibilityHint(isOwner ? "Renames the batch" : "")
            if let text = collection.description, !text.isEmpty {
                Text(text)
                    .font((collection.font ?? .classic).font(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { if isOwner { showDescription = true } }
                    .accessibilityAddTraits(isOwner ? .isButton : [])
                    .accessibilityHint(isOwner ? "Edits the description" : "")
            } else if isOwner {
                Button("Add a description", systemImage: "plus") { showDescription = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(introLine).metaStyle(.caption)
            if !isOwner, let owner = collection.owner {
                Button { onOpenOwner?(owner) } label: {
                    HStack(spacing: 8) {
                        AvatarView(user: owner, size: 24)
                        Text(owner.displayName).font(.subheadline.weight(.semibold))
                        if onOpenOwner != nil {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpenOwner == nil)
                .padding(.top, 2)
            }
            if !isOwner && collection.canAdd {
                Label("Group batch · you can add photos", systemImage: "plus.rectangle.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.strewnAccent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.strewnAccent.opacity(0.12), in: Capsule())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    private var introLine: String {
        var parts: [String] = []
        if let date = collection.shotOn { parts.append(date.formatted(.dateTime.month(.wide).day().year())) }
        if let place = collection.place { parts.append(place) }
        parts.append(collection.photos.count.counted("frame"))
        return parts.joined(separator: " · ")
    }

    private var canAdd: Bool { isOwner || collection.canAdd }

    /// The editor saves into your own piles, so it's for your photos in your piles.
    private func canEdit(_ photo: Photo) -> Bool {
        isOwner && photo.addedBy == nil
    }

    /// The owner removes anything; a friend, only what they added.
    private func canRemove(_ photo: Photo) -> Bool {
        isOwner || (photo.addedBy != nil && photo.addedBy == model.me?.id)
    }

    /// Anyone's photo but your own can be reported, in your batch or theirs.
    private func canReport(_ photo: Photo) -> Bool {
        guard let me = model.me?.id else { return false }
        let adder = photo.addedBy ?? collection.ownerID
        return adder != me
    }

    /// The viewer is a full-screen cover, so it closes before the report sheet opens.
    private func report(_ photo: Photo) {
        let target = ReportTarget(subject: "this photo", report: Report(photoID: photo.id, reason: .other),
                                  owner: collection.adder(of: photo) ?? collection.owner)
        guard viewerPhoto != nil else { reporting = target; return }
        viewerPhoto = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            reporting = target
        }
    }

    private func remove(_ photo: Photo) {
        if isOwner {
            model.removePhotos([photo.id], from: collection.id)
        } else {
            model.removeContributed([photo.id], from: collection.id)
        }
    }

    /// The viewer is a full-screen cover, so it closes before the sharing sheet opens.
    private func openShareSettings() {
        viewerPhoto = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            showShare = true
        }
    }

    private func startRename() {
        renameDraft = collection.title
        renaming = true
    }

    /// The viewer and the editor are both full-screen covers, so the viewer goes first.
    private func edit(_ photo: Photo) {
        viewerPhoto = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            editingPhoto = photo
        }
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .frame(width: 38, height: 38)
            // Follows the wall's text color, so it shows on light, dark and desk walls alike.
            .background(.foreground.opacity(0.1), in: Circle())
            .contentShape(Circle())
    }

    private var subtitle: String {
        var parts = [collection.photos.count.counted("frame")]
        if let owner = collection.owner, !isOwner { parts.append("@\(owner.handle)") }
        if isOwner { parts.append(collection.visibility.title.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private func close() {
        // let go of the pull in step with the photos flying back, so they leave from where they were
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { pull = 0; headerPull = 0 }
        appeared = false
        onClose()
    }

    /// Optimistic: the heart fills straight away and goes back if the server says no.
    private func like(_ photo: Photo) {
        guard var mine = reactions?[photo.id] else { return }
        let before = mine
        mine.likedByMe.toggle()
        mine.likeCount = max(0, mine.likeCount + (mine.likedByMe ? 1 : -1))
        reactions?[photo.id] = mine
        Task {
            do { try await model.setLiked(mine.likedByMe, photoID: photo.id) }
            catch { reactions?[photo.id] = before }
        }
    }

    private func setCommentCount(_ count: Int, for photo: Photo) {
        reactions?[photo.id]?.commentCount = count
    }
}

/// The quiet line under a print: its frame number and what's known about it, and a star on
/// the cover. Actions live in the viewer and the long-press menu, so the wall stays a wall.
struct PhotoMetaRow: View {
    let collection: PhotoCollection
    let photo: Photo
    let index: Int
    var reactions: PhotoReactions? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(exifLine).metaStyle().lineLimit(1)
            Spacer(minLength: 4)
            if let reactions { ReactionsLine(reactions: reactions) }
            if let adder = collection.adder(of: photo) {
                HStack(spacing: 4) {
                    AvatarView(user: adder, size: 16)
                    Text(adder.displayName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Added by \(adder.displayName)")
            }
            if photo.id == collection.cover?.id {
                Label("Cover", systemImage: "star.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.strewnAccent)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .animation(.snappy, value: collection.coverPhotoID)
    }

    private var exifLine: String {
        var parts = [String(format: "%02d", index + 1)]
        if let f = photo.exif?.aperture { parts.append("ƒ\(f.formatted())") }
        if let s = photo.exif?.shutter { parts.append(s) }
        if let iso = photo.exif?.iso { parts.append("ISO \(iso)") }
        if photo.edit != nil { parts.append("edited") }
        return parts.joined(separator: " · ")
    }
}

/// Two-column masonry: each photo keeps its own height, so nothing is cropped to a square.
struct MasonryLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let heights = place(subviews: subviews, width: width).heights
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = place(subviews: subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(width: result.columnWidth, height: nil))
        }
    }

    private func place(subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], heights: [CGFloat], columnWidth: CGFloat) {
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat.zero, count: columns)
        var origins: [CGPoint] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: heights[column]))
            heights[column] += size.height + spacing
        }
        return (origins, heights, columnWidth)
    }
}

/// Notes when the gallery has scrolled past its title. iOS 18 reads the scroll; on iOS 17
/// the header simply always shows the title.
private struct TitleScrollTracker: ViewModifier {
    @Binding var scrolledAway: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 70 } action: { _, away in
                scrolledAway = away
            }
        } else {
            content.onAppear { scrolledAway = true }
        }
    }
}

/// Drag photos into the order the pile should show them in.
private struct ReorderPhotosSheet: View {
    let collectionID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var photos: [Photo] { model.myCollections.first { $0.id == collectionID }?.photos ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: "Reorder photos", cancelTitle: nil, confirmTitle: "Done", onConfirm: { dismiss() })
            List {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    HStack(spacing: 14) {
                        PhotoImage(photo: photo)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(String(format: "%02d", index + 1)).metaStyle(.subheadline)
                        if let caption = photo.caption { Text(caption).font(.subheadline).lineLimit(1) }
                    }
                    .listRowBackground(Color.card)
                }
                .onMove { model.movePhotos(in: collectionID, from: $0, to: $1) }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
    }
}
