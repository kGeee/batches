import SwiftUI

/// Piles from people you follow and piles shared with you, framed the way their owners set them.
struct FriendsFeedView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var feedSpace
    @State private var openID: UUID?
    /// Every push here goes through this path by value. Mixing in a view-based link (as Find
    /// people used to be) makes SwiftUI insert later pushes underneath it.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if model.feed.isEmpty { emptyState }
                        ForEach(model.feed) { collection in
                            card(collection)
                        }
                    }
                    .padding(14)
                }
                .background(DeskMatBackground())
                .refreshable { await model.refresh() }

                if let openID, let collection = model.feed.first(where: { $0.id == openID }) {
                    GalleryView(collection: collection, namespace: feedSpace, isOwner: false,
                                onOpenOwner: { owner in
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.openID = nil }
                                    path.append(owner)
                                }) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.openID = nil }
                    }
                    .zIndex(1)
                }
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(openID == nil ? .automatic : .hidden, for: .navigationBar, .tabBar)
            // A batch that left the feed while open (its owner was blocked) closes with it.
            .onChange(of: model.feed) { _, feed in
                if let id = openID, !feed.contains(where: { $0.id == id }) { openID = nil }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Friends").titleStyle(.headline) }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: FindPeopleRoute()) { Label("Find people", systemImage: "person.badge.plus") }
                }
            }
            .navigationDestination(for: User.self) { ProfileView(user: $0) }
            .navigationDestination(for: FindPeopleRoute.self) { _ in FindPeopleView() }
        }
    }

    private func card(_ collection: PhotoCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let owner = collection.owner {
                NavigationLink(value: owner) {
                    HStack(spacing: 10) {
                        AvatarView(user: owner, size: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(owner.displayName).font(.subheadline.weight(.semibold))
                            Text(byline(collection, owner: owner)).metaStyle().lineLimit(1)
                        }
                        Spacer()
                        if collection.canAdd {
                            Label("Group", systemImage: "plus.rectangle.on.rectangle")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.strewnAccent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.strewnAccent.opacity(0.12), in: Capsule())
                                .accessibilityLabel("Group batch, you can add photos")
                        } else if collection.visibility == .people {
                            Label("For you", systemImage: "person.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.strewnAccent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.strewnAccent.opacity(0.12), in: Capsule())
                                .accessibilityLabel("Shared with you")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if openID == collection.id {
                Color.clear.aspectRatio(5 / 4, contentMode: .fit)
            } else {
                DeskPileView(collection: collection, namespace: feedSpace)
                    .aspectRatio(5 / 4, contentMode: .fit)
                    // The pile is square; centered in the card, not pushed to its leading edge.
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = collection.id } }
            }
            // Likes and comments come back here once the backend has them; until then
            // there's nothing to tap, so nothing is shown.
            PileCaption(collection: collection)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func byline(_ collection: PhotoCollection, owner: User) -> String {
        var parts = ["@\(owner.handle)"]
        if let date = collection.shotOn { parts.append(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing here yet").titleStyle(.title3)
            Text("Follow friends to see the batches they share with followers. Batches shared with you directly show up here too.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink(value: FindPeopleRoute()) { Text("Find people") }
                .buttonStyle(.borderedProminent).tint(.strewnAccent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Opens Find people from the Friends stack.
struct FindPeopleRoute: Hashable {}
