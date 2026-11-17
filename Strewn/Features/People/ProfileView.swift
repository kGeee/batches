import SwiftUI

/// Someone's desk: their profile, the piles you're allowed to see, and batches they're tagged in.
struct ProfileView: View {
    enum Section: Hashable { case batches, tagged }

    let user: User
    @Environment(AppModel.self) private var model
    @Namespace private var pileSpace
    @State private var profile: User?
    @State private var piles: [PhotoCollection] = []
    @State private var taggedPiles: [PhotoCollection] = []
    @State private var section = Section.batches
    @State private var loaded = false
    @State private var openID: UUID?
    @State private var reporting = false
    @State private var confirmingBlock = false

    private var shown: User { profile ?? user }
    private var isMe: Bool { user.id == model.me?.id }
    private var activePiles: [PhotoCollection] { section == .batches ? piles : taggedPiles }
    @Environment(\.windowLayout) private var window
    private var columns: [GridItem] { window.grid(alignment: .center) }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !isMe && model.isBlocked(shown) {
                        VStack(spacing: 10) {
                            Text("You've blocked @\(shown.handle).").font(.callout).foregroundStyle(.secondary)
                            Button("Unblock") { Task { await model.unblock(shown); await load() } }.buttonStyle(.bordered)
                        }
                        .padding(.top, 24).frame(maxWidth: .infinity)
                    } else {
                        if !taggedPiles.isEmpty || section == .tagged {
                            PaperSegmented(selection: $section, options: [
                                (.batches, "Batches"),
                                (.tagged, taggedPiles.isEmpty ? "Tagged" : "Tagged · \(taggedPiles.count)")
                            ])
                        }
                        if loaded && activePiles.isEmpty {
                            Text(section == .tagged
                                 ? (isMe ? "Batches you're tagged in show up here." : "No visible batches tag \(shown.displayName) yet.")
                                 : (isMe ? "No batches yet." : "Nothing of \(shown.displayName)'s is shared with you yet."))
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 24).frame(maxWidth: .infinity)
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(activePiles) { pile in
                                VStack(alignment: .leading, spacing: 2) {
                                    if openID == pile.id {
                                        Color.clear.aspectRatio(1, contentMode: .fit)
                                    } else {
                                        DeskPileView(collection: pile, namespace: pileSpace)
                                            .contentShape(Rectangle())
                                            .onTapGesture { withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = pile.id } }
                                    }
                                    PileCaption(collection: pile, showsVisibility: isMe && pile.ownerID == model.me?.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .background(DeskMatBackground())
            .refreshable { await load() }

            if let openID, let pile = (piles + taggedPiles).first(where: { $0.id == openID }) {
                GalleryView(collection: pile, namespace: pileSpace, isOwner: pile.ownerID == model.me?.id) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.openID = nil }
                }
                .zIndex(1)
            }
        }
        .paperNavigationTitle("@\(shown.handle)")
        .toolbar(openID == nil ? .automatic : .hidden, for: .navigationBar)
        .coversTabBar(openID != nil, key: "profile-\(user.id)")
        .onChange(of: piles + taggedPiles) { _, allPiles in
            if let id = openID, !allPiles.contains(where: { $0.id == id }) { openID = nil }
        }
        .toolbar {
            if !isMe {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PersonSafetyMenu(user: shown, reporting: $reporting, confirmingBlock: $confirmingBlock)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $reporting) {
            ReportSheet(subject: "@\(shown.handle)", report: Report(userID: shown.id, reason: .other), owner: shown)
        }
        .confirmationDialog("Block @\(shown.handle)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await model.block(shown); await load() } }
        } message: {
            Text("Neither of you will see the other's batches, you'll stop following each other, and batches shared between you stop being shared. They aren't told.")
        }
        .task { await load() }
        .onChange(of: model.following) { Task { await load() } }
        // Photos you add to one of their group piles land in the feed first.
        .onChange(of: model.feed) { Task { await load() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AvatarView(user: shown, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.displayName).titleStyle(.title2, weight: .bold)
                if isMe {
                    Text(piles.count.counted("batch", plural: "batches")).metaStyle()
                    // Your own counts open the lists of who they are.
                    HStack(spacing: 4) {
                        NavigationLink(value: FollowListRoute(user: shown, tab: .followers)) {
                            Text(shown.followerCount.counted("follower")).metaStyle().underline().roomyTapTarget()
                        }
                        Text("·").metaStyle()
                        NavigationLink(value: FollowListRoute(user: shown, tab: .following)) {
                            Text("\(shown.followingCount) following").metaStyle().underline().roomyTapTarget()
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("\(piles.count.counted("batch", plural: "batches")) · \(shown.followerCount.counted("follower")) · \(shown.followingCount) following")
                        .metaStyle().lineLimit(2)
                }
            }
            Spacer()
            if !isMe && !model.isBlocked(shown) { FollowButton(user: shown) }
        }
        .padding(.top, 12)
    }

    private func load() async {
        async let p = model.profile(user.id)
        async let list = model.piles(of: user)
        async let tagged = model.taggedPiles(of: user)
        (profile, piles, taggedPiles) = await (p, list, tagged)
        loaded = true
    }
}
