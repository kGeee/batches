import PhotosUI
import SwiftUI

/// Batches from people you follow and batches shared with you, with what people did to your own
/// photos under Activity.
struct FriendsFeedView: View {
    enum Section: Hashable { case batches, activity }

    @Environment(AppModel.self) private var model
    @Environment(AppChrome.self) private var chrome: AppChrome?
    @Namespace private var feedSpace
    @State private var section = Section.batches
    @State private var openID: UUID?
    /// Opened from Activity: the photo it was about, shown as soon as the batch is up.
    @State private var openPhotoID: UUID?
    /// Activity newer than this gets a dot. Kept from before the list was opened, which marks it all seen.
    @State private var dotsSince = Date.distantFuture
    /// Every push here goes through this path by value. Mixing in a view-based link (as Find
    /// people used to be) makes SwiftUI insert later pushes underneath it.
    @State private var path = NavigationPath()

    /// The open batch: a friend's from the feed, or one of yours opened from Activity.
    private var open: PhotoCollection? {
        guard let openID else { return nil }
        return model.feed.first { $0.id == openID } ?? model.myCollections.first { $0.id == openID }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            switch section {
                            case .batches: batches
                            case .activity: activity
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await model.refresh() }
                }
                .background(DeskMatBackground())

                if let open {
                    GalleryView(collection: open, namespace: feedSpace, isOwner: open.ownerID == model.me?.id,
                                onOpenOwner: { owner in
                                    close()
                                    path.append(owner)
                                },
                                startPhotoID: openPhotoID) {
                        close()
                    }
                    .zIndex(1)
                }
            }
            .navigationTitle("Friends")
            .toolbar(.hidden, for: .navigationBar)
            .coversTabBar(openID != nil, key: "friends")
            // A batch that left the feed while open (its owner was blocked) closes with it.
            .onChange(of: model.feed) { _, _ in
                if openID != nil, open == nil { openID = nil }
            }
            .onChange(of: openID) { before, now in
                if before != nil, now == nil { Task { await model.refreshSocial() } }
            }
            .onChange(of: section, initial: true) { _, now in showActivityIfNeeded(now) }
            .onChange(of: chrome?.showsActivity) { _, wanted in
                guard wanted == true else { return }
                chrome?.showsActivity = false
                withAnimation(.snappy) { section = .activity }
            }
            .navigationDestination(for: User.self) { ProfileView(user: $0) }
            .navigationDestination(for: FindPeopleRoute.self) { _ in FindPeopleView() }
            .navigationDestination(for: FollowListRoute.self) { FollowListView(route: $0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Friends").titleStyle(.largeTitle, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink(value: FindPeopleRoute()) {
                    Image(systemName: "person.badge.plus").font(.body.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.strewnAccent.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Find people")
            }
            PaperSegmented(selection: $section, options: [
                (.batches, "Batches"),
                (.activity, model.unseenActivity.isEmpty ? "Activity" : "Activity · \(model.unseenActivity.count)")
            ])
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func close() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { openID = nil }
        openPhotoID = nil
    }

    /// Opening Activity marks it seen, but the dots stay on what was new until you leave.
    private func showActivityIfNeeded(_ now: Section) {
        if now == .activity {
            dotsSince = model.activitySeenAt
            model.markActivitySeen()
        } else {
            dotsSince = .distantFuture
        }
    }

    // MARK: Batches

    @ViewBuilder
    private var batches: some View {
        if model.feed.isEmpty { emptyState }
        ForEach(model.feed) { collection in
            FeedCard(collection: collection, namespace: feedSpace, isOpen: openID == collection.id,
                     totals: model.batchTotals[collection.id]) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = collection.id }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing here yet").titleStyle(.title3)
            Text("Follow friends to see the batches they share with followers. Batches shared with you directly show up here too.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink(value: FindPeopleRoute()) { Text("Find people") }
                .buttonStyle(.borderedProminent).tint(.strewnAccent).foregroundStyle(Color.onAccent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Activity

    @ViewBuilder
    private var activity: some View {
        if model.activity.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "heart").font(.largeTitle).foregroundStyle(.secondary)
                Text("No activity yet").titleStyle(.title3)
                Text("When someone likes or comments on a photo in a batch you've shared, it shows up here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.activity.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { PaperDivider(inset: 58) }
                    activityRow(item)
                }
            }
            .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        let batch = model.batch(containing: item.photoID)
        let photo = batch?.photos.first { $0.id == item.photoID }
        let name = item.actor?.displayName ?? "Someone"
        return Button {
            guard let batch else { return }
            openPhotoID = item.photoID
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = batch.id }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(user: item.actor, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    switch item.kind {
                    case .like:
                        (Text(name).fontWeight(.semibold) + Text(" liked your photo"))
                            .font(.subheadline).multilineTextAlignment(.leading)
                    case .comment(let body):
                        (Text(name).fontWeight(.semibold) + Text(" commented: \(body)"))
                            .font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    // The time first: a long title is what gets cut short.
                    Text(([item.at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))]
                          + [batch?.title].compactMap { $0 }).joined(separator: " · "))
                        .metaStyle().lineLimit(1)
                }
                Spacer(minLength: 4)
                if item.at > dotsSince {
                    Circle().fill(Color.strewnAccent).frame(width: 8, height: 8).padding(.top, 6)
                        .accessibilityLabel("New")
                }
                if let photo {
                    // The whole photo, small: never cropped to a square.
                    PhotoImage(photo: photo)
                        .frame(maxWidth: 48, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One batch in the feed: whose it is, its first few frames as whole prints, and its likes and
/// comments. A group batch you can add to has the button for that right on the card.
private struct FeedCard: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let isOpen: Bool
    let totals: PhotoReactions?
    let onOpen: () -> Void

    @Environment(AppModel.self) private var model
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let owner = collection.owner {
                NavigationLink(value: owner) {
                    HStack(spacing: 10) {
                        AvatarView(user: owner, size: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(owner.displayName).font(.subheadline.weight(.semibold))
                            Text(byline(owner)).metaStyle().lineLimit(1)
                        }
                        Spacer()
                        if collection.canAdd {
                            badge("Group", "plus.rectangle.on.rectangle").accessibilityLabel("Group batch, you can add photos")
                        } else if collection.visibility == .people {
                            badge("For you", "person.2.fill").accessibilityLabel("Shared with you")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // While the batch is open its prints are in the gallery; the card keeps their room.
            FeedPrints(collection: collection, namespace: namespace, placeholder: isOpen)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
            PileCaption(collection: collection)
            if showsFooter {
                HStack(spacing: 10) {
                    if let totals, totals.likeCount + totals.commentCount > 0 { ReactionsLine(reactions: totals) }
                    Spacer(minLength: 4)
                    if collection.canAdd { addYours }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                let photos = await PhotoImport.photos(from: items, collectionID: collection.id)
                await model.contribute(photos, to: collection.id)
                picked = []
                importing = false
            }
        }
    }

    private var showsFooter: Bool {
        collection.canAdd || (totals.map { $0.likeCount + $0.commentCount > 0 } ?? false)
    }

    private var addYours: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: 60, matching: .images,
                     preferredItemEncoding: .current, photoLibrary: .shared()) {
            HStack(spacing: 6) {
                if importing { ProgressView().tint(Color.onAccent) } else { Image(systemName: "plus").font(.footnote.weight(.bold)) }
                Text("Add yours").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.strewnAccent, in: Capsule())
        }
        .disabled(importing)
        .accessibilityLabel("Add your photos to \(collection.title)")
    }

    private func badge(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.strewnAccent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.strewnAccent.opacity(0.12), in: Capsule())
    }

    private func byline(_ owner: User) -> String {
        var parts = ["@\(owner.handle)"]
        if let date = collection.shotOn { parts.append(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) }
        return parts.joined(separator: " · ")
    }
}

/// The cover and the next frame or two, side by side at one height, each a whole print.
private struct FeedPrints: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let placeholder: Bool

    private static let paper: CGFloat = 5

    /// The cover first, then what follows it, for as long as the row stays a decent height.
    private var shown: [Photo] {
        guard let cover = collection.cover else { return [] }
        var photos = [cover]
        for photo in collection.photos where photo.id != cover.id && photos.count < 3 {
            // Each print added makes the row shorter; a panorama can leave no room for more.
            if (photos + [photo]).reduce(0, { $0 + $1.aspectRatio }) > 3.4 { break }
            photos.append(photo)
        }
        return photos
    }

    var body: some View {
        let photos = shown
        let more = collection.photos.count - photos.count
        JustifiedRow(aspects: photos.map(\.aspectRatio), paper: Self.paper) {
            ForEach(photos) { photo in
                if placeholder {
                    Color.clear
                } else {
                    PrintView(photo: photo, paper: Self.paper)
                        .matchedGeometryEffect(id: photo.id, in: namespace)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if more > 0, !placeholder {
                Text("+\(more)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(Self.paper + 5)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.title), \(collection.photos.count) photos")
        .accessibilityAddTraits(.isButton)
    }
}

/// Lays prints out in one row at a shared height, each as wide as its photo needs, so the row
/// fills the width and nothing is cropped.
private struct JustifiedRow: Layout {
    let aspects: [CGFloat]
    var paper: CGFloat = 5
    var spacing: CGFloat = 8
    var maxHeight: CGFloat = 230

    /// The print height at which the row is exactly `width` wide, capped for a lone portrait.
    private func height(for width: CGFloat) -> CGFloat {
        let total = aspects.reduce(0, +)
        guard total > 0 else { return 0 }
        let count = CGFloat(aspects.count)
        let photoHeight = (width - 2 * paper * count - spacing * (count - 1)) / total
        return min(maxHeight, max(0, photoHeight) + 2 * paper)
    }

    private func width(of aspect: CGFloat, height: CGFloat) -> CGFloat { aspect * (height - 2 * paper) + 2 * paper }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        return CGSize(width: width, height: height(for: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = height(for: bounds.width)
        let widths = aspects.map { width(of: $0, height: height) }
        let used = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        var x = bounds.minX + (bounds.width - used) / 2
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: height))
            x += width + spacing
        }
    }
}

/// Opens Find people from the Friends stack.
struct FindPeopleRoute: Hashable {}
