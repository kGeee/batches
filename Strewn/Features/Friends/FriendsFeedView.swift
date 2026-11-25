import PhotosUI
import SwiftUI
import UserNotifications

/// Batches from people you follow and batches shared with you, with what people did to your own
/// photos under Activity.
struct FriendsFeedView: View {
    enum Section: Hashable { case batches, activity }

    @Environment(AppModel.self) private var model
    @Environment(AppChrome.self) private var chrome: AppChrome?
    @Environment(\.windowLayout) private var window
    @Namespace private var feedSpace
    @State private var section = Section.batches
    @State private var openID: UUID?
    @State private var openPileFallback: PhotoCollection?
    /// Opened from Notifications: the photo it was about, shown as soon as the batch is up.
    @State private var openPhotoID: UUID?
    /// Notification IDs that were unread when the list opened, so their dots stay while reading.
    @State private var unreadIDsOnOpen: Set<String> = []
    @State private var pushAuthStatus: UNAuthorizationStatus = .notDetermined
    /// Every push here goes through this path by value. Mixing in a view-based link (as Find
    /// people used to be) makes SwiftUI insert later pushes underneath it.
    @State private var path = NavigationPath()

    /// The open batch: a friend's from the feed, one of yours, or one fetched from a notification.
    private var open: PhotoCollection? {
        guard let openID else { return nil }
        return model.feed.first { $0.id == openID }
            ?? model.myCollections.first { $0.id == openID }
            ?? (openPileFallback?.id == openID ? openPileFallback : nil)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        Group {
                            switch section {
                            // Side by side when there's room; one card wide on a phone-sized window.
                            case .batches:
                                if model.feed.isEmpty { emptyState } else {
                                    LazyVGrid(columns: window.feedGrid(spacing: 22), spacing: 30) { batches }
                                }
                            case .activity:
                                LazyVStack(spacing: 14) { activity }
                                    .frame(maxWidth: window.isWide ? window.readableWidth : nil)
                                    .frame(maxWidth: .infinity)
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
                Text("Friends").titleStyle(.largeTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink(value: FindPeopleRoute()) {
                    Text("Find people").font(.subheadline).foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
            HStack(spacing: 22) {
                sectionTab(.batches, "Batches")
                sectionTab(.activity, model.unseenActivity.isEmpty ? "Activity" : "Activity, \(model.unseenActivity.count) new")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func sectionTab(_ value: Section, _ title: String) -> some View {
        let selected = section == value
        return Button {
            withAnimation(.snappy(duration: 0.2)) { section = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func close() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { openID = nil }
        openPhotoID = nil
        openPileFallback = nil
    }

    /// Opening Notifications marks them read, while keeping the dots on what was new until you leave.
    private func showActivityIfNeeded(_ now: Section) {
        if now == .activity {
            unreadIDsOnOpen = Set(model.unseenActivity.map(\.id))
            model.markActivitySeen()
            Task {
                await model.push?.refreshAuthorizationStatus()
                pushAuthStatus = model.push?.authorizationStatus ?? .notDetermined
            }
        } else {
            unreadIDsOnOpen = []
        }
    }

    // MARK: Batches

    @ViewBuilder
    private var batches: some View {
        ForEach(model.feed) { collection in
            FeedCard(collection: collection, namespace: feedSpace, isOpen: openID == collection.id,
                     totals: model.batchTotals[collection.id]) { photo in
                // The cover opens the batch; any other photo opens the batch and then that photo.
                openPhotoID = photo?.id == collection.cover?.id ? nil : photo?.id
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = collection.id }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Nothing here yet").titleStyle(.title3)
            Text("Follow friends to see the batches they share with followers. Batches shared with you directly show up here too.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink(value: FindPeopleRoute()) { Text("Find people").font(.subheadline.weight(.medium)) }
                .foregroundStyle(Color.strewnAccent)
                .frame(minHeight: 44)
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: Notifications

    @ViewBuilder
    private var activity: some View {
        if pushAuthStatus == .notDetermined {
            pushPermissionPrompt
        }
        if model.activity.isEmpty {
            VStack(spacing: 12) {
                Text("Nothing new").titleStyle(.title3)
                Text("When someone tags you, mentions you, shares a batch, follows you, or reacts to your photos, it shows up here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.vertical, 48)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
        } else {
            // A plain list on the fog: hairlines between, no card.
            VStack(spacing: 0) {
                ForEach(Array(model.activity.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
                    activityRow(item)
                }
            }
        }
    }

    private var pushPermissionPrompt: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Hear about it straight away when someone tags you or shares a batch.")
                .font(.system(.callout, design: .serif).italic())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Turn on") {
                Task {
                    _ = await model.push?.requestPermission()
                    pushAuthStatus = model.push?.authorizationStatus ?? .denied
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.strewnAccent)
            .frame(minHeight: 44)
        }
        .padding(.bottom, 6)
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        let localBatch = item.collectionID.flatMap { id in (model.myCollections + model.feed).first { $0.id == id } }
            ?? item.photoID.flatMap { model.batch(containing: $0) }
        let photo = item.photoID.flatMap { pid in localBatch?.photos.first { $0.id == pid } } ?? localBatch?.cover
        let name = item.actor?.displayName ?? "Someone"
        let title = item.batchTitle ?? localBatch?.title
        let isNew = unreadIDsOnOpen.contains(item.id) || model.isUnread(item)
        return Button {
            openNotification(item, localBatch: localBatch)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    notificationText(name: name, item: item)
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(([item.at.formatted(.relative(presentation: .named, unitsStyle: .wide))]
                          + [title].compactMap { $0 }).joined(separator: ", "))
                        .metaStyle().lineLimit(1)
                }
                Spacer(minLength: 4)
                if isNew {
                    Circle().fill(Color.strewnAccent).frame(width: 8, height: 8).padding(.top, 6)
                        .accessibilityLabel("New")
                }
                if case .follow = item.kind, let actor = item.actor, actor.id != model.me?.id {
                    FollowButton(user: actor)
                } else if let photo {
                    // The whole photo, small: never cropped to a square.
                    PhotoImage(photo: photo)
                        .frame(maxWidth: 52, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func notificationText(name: String, item: ActivityItem) -> Text {
        let bold = Text(name).fontWeight(.medium)
        switch item.kind {
        case .like:
            return bold + Text(" liked your photo")
        case .comment(let body):
            return bold + Text(" commented: \(body)")
        case .mention(let body):
            return bold + Text(" mentioned you: \(body)")
        case .tag:
            return bold + Text(" tagged you in a photo")
        case .batchShared(let canAdd):
            return bold + Text(canAdd ? " invited you to add photos to a batch" : " shared a batch with you")
        case .photoAdded(let count):
            return bold + Text(" added \(count == 1 ? "a photo" : "\(count) photos") to your batch")
        case .follow:
            return bold + Text(" started following you")
        }
    }

    private func openNotification(_ item: ActivityItem, localBatch: PhotoCollection?) {
        model.markNotificationRead(item.id)
        if case .follow = item.kind, let actor = item.actor {
            path.append(actor)
            return
        }
        if let localBatch {
            openPhotoID = item.photoID
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = localBatch.id }
            return
        }
        if let cid = item.collectionID {
            Task {
                if let fetched = await model.collection(id: cid) {
                    openPileFallback = fetched
                    openPhotoID = item.photoID
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = fetched.id }
                } else if let actor = item.actor {
                    path.append(actor)
                }
            }
        } else if let actor = item.actor {
            path.append(actor)
        }
    }
}

/// One batch in the feed: whose it is, its first few frames as whole prints, and its likes and
/// comments. A group batch you can add to has the button for that right on the card.
private struct FeedCard: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let isOpen: Bool
    let totals: PhotoReactions?
    let onOpen: (Photo?) -> Void

    @Environment(AppModel.self) private var model
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var google = GooglePhotosPicking()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let owner = collection.owner {
                NavigationLink(value: owner) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(owner.displayName).font(.footnote.weight(.medium)).foregroundStyle(.primary)
                        Text(byline).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let place = collection.place {
                            Text(place).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // While the batch is open its prints are in the gallery; the card keeps their room.
            FeedPrints(collection: collection, namespace: namespace, placeholder: isOpen, onOpen: onOpen)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(collection.title).batchTitle(collection.font, .body).lineLimit(2)
                Spacer(minLength: 4)
                if collection.canAdd {
                    addYours
                } else {
                    Text(note ?? collection.photos.count.counted("frame")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            GooglePhotosStatus(picking: google)
        }
        .animation(.snappy, value: google.stage)
        .googlePhotosAlert(google)
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

    private var addYours: some View {
        PhotoSourcePicker(selection: $picked, onGooglePhotos: importFromGoogle) {
            HStack(spacing: 4) {
                Text("Group, you can add").font(.caption)
                if importing || google.isRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "plus").font(.caption) }
            }
            .foregroundStyle(Color.strewnAccent)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .disabled(importing || google.isRunning)
        .accessibilityLabel("Add your photos to \(collection.title)")
    }

    private func importFromGoogle() {
        Task {
            let photos = await google.run(collectionID: collection.id)
            guard !photos.isEmpty else { return }
            importing = true
            await model.contribute(photos, to: collection.id)
            importing = false
        }
    }

    /// A batch shared with you alone says so beside the title, instead of its frame count.
    private var note: String? {
        collection.visibility == .people ? "For you" : nil
    }

    /// When, and the likes and comments if there are any: "2 days ago, 3 likes".
    private var byline: String {
        var parts = [collection.shotOn?.formatted(.relative(presentation: .named, unitsStyle: .wide))].compactMap { $0 }
        if let totals {
            if totals.likeCount > 0 { parts.append(totals.likeCount.counted("like")) }
            if totals.commentCount > 0 { parts.append(totals.commentCount.counted("comment")) }
        }
        return parts.joined(separator: ", ")
    }
}

/// The batch's photos in a strip you can scroll sideways: the cover large, the rest smaller, all
/// at one short height, with the next one peeking in at the edge so it reads as more to see.
/// A batch of one shows its cover alone, the full width.
private struct FeedPrints: View {
    let collection: PhotoCollection
    let namespace: Namespace.ID
    let placeholder: Bool
    let onOpen: (Photo?) -> Void

    private static let gap: CGFloat = 6
    /// The feed's side margin, which the strip scrolls out into.
    private static let bleed: CGFloat = 14

    private var photos: [Photo] {
        guard let cover = collection.cover else { return collection.photos }
        return [cover] + collection.photos.filter { $0.id != cover.id }
    }

    var body: some View {
        let photos = photos
        Color.clear
            .aspectRatio(photos.count == 1 ? 2 : 2.3, contentMode: .fit)
            .overlay {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Self.gap) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            Group {
                                if placeholder {
                                    Color.clear
                                } else {
                                    PhotoImage(photo: photo)
                                        .aspectRatio(photo.aspectRatio, contentMode: .fill)
                                        .containerRelativeFrame(.horizontal) { width, _ in share(index, of: photos.count, in: width) }
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                        .matchedGeometryEffect(id: photo.id, in: namespace)
                                }
                            }
                            .containerRelativeFrame(.horizontal) { width, _ in share(index, of: photos.count, in: width) }
                            .containerRelativeFrame(.vertical)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(photo) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(index == 0 ? "\(collection.title), cover" : "Photo \(index + 1) of \(photos.count)")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollDisabled(photos.count < 3 || placeholder)
                // Runs out to the screen edge while scrolling, but rests lined up with the text.
                .contentMargins(.horizontal, Self.bleed, for: .scrollContent)
                .padding(.horizontal, -Self.bleed)
            }
            .frame(maxWidth: .infinity)
    }

    /// How wide a photo is in the strip: the cover most of the width, the rest about a third, so
    /// with three or more the third shows a sliver at the edge.
    private func share(_ index: Int, of count: Int, in width: CGFloat) -> CGFloat {
        switch count {
        case 1: return width
        case 2: return index == 0 ? (width - Self.gap) * 2 / 3 : (width - Self.gap) / 3
        default: return index == 0 ? width * 0.62 : width * 0.3
        }
    }
}

/// Opens Find people from the Friends stack.
struct FindPeopleRoute: Hashable {}
