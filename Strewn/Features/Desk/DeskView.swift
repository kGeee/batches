import SwiftUI

/// Your desk: profile header and your piles. Tapping a pile spreads it into the gallery.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pileSpace
    @State private var openID: UUID?
    @State private var showNewPile = false
    @State private var sharing: PileRef?
    @State private var showAccount = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProfileHeader(user: model.me, pileCount: model.myCollections.count,
                                  frameCount: model.myCollections.reduce(0) { $0 + $1.photos.count },
                                  onNewPile: { showNewPile = true }, onAccount: { showAccount = true })
                    if model.myCollections.isEmpty {
                        EmptyDesk { showNewPile = true }
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.myCollections) { collection in
                            pileCell(collection)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .background(DeskMatBackground())
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showNewPile) { NewPileSheet() }
            .sheet(item: $sharing) { SharePileSheet(collectionID: $0.id) }
            .sheet(isPresented: $showAccount) { AccountSheet() }
            .sensoryFeedback(.impact(weight: .light), trigger: openID)
            // The gallery gets the whole screen, as it does from Friends.
            .toolbar(openID == nil ? .automatic : .hidden, for: .tabBar)

            if let openID, let collection = model.myCollections.first(where: { $0.id == openID }) {
                GalleryView(collection: collection, namespace: pileSpace, isOwner: true) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.openID = nil }
                }
                .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private func pileCell(_ collection: PhotoCollection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if openID == collection.id {
                    // Keep the slot so the grid does not reflow while the pile is spread out.
                    Color.clear.aspectRatio(1, contentMode: .fit)
                } else {
                    DeskPileView(collection: collection, namespace: pileSpace)
                        .contentShape(Rectangle())
                        .onTapGesture { open(collection) }
                        .contextMenu {
                            Button("Open", systemImage: "rectangle.expand.vertical") { open(collection) }
                            Button("Share…", systemImage: "square.and.arrow.up") { sharing = PileRef(id: collection.id) }
                            Button("Delete batch", systemImage: "trash", role: .destructive) { model.deletePile(collection.id) }
                        }
                }
            }
            PileCaption(collection: collection, showsVisibility: true)
        }
    }

    private func open(_ collection: PhotoCollection) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = collection.id }
    }
}

struct PileCaption: View {
    let collection: PhotoCollection
    /// Your own piles show who can see them.
    var showsVisibility = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if showsVisibility {
                    Image(systemName: collection.visibility.symbol).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel(collection.visibility.title)
                }
                Text(collection.title).titleStyle(.subheadline).lineLimit(2)
            }
            Text(metaLine).metaStyle().lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private var metaLine: String {
        var parts = [collection.photos.count.counted("frame")]
        if let date = collection.shotOn { parts.append(date.formatted(.dateTime.month(.abbreviated).day())) }
        if let place = collection.place { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}

/// The top of your desk: who you are, what's on it, and the two things you do from here.
struct ProfileHeader: View {
    let user: User?
    let pileCount: Int
    let frameCount: Int
    var onNewPile: () -> Void = {}
    var onAccount: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.displayName ?? " ").titleStyle(.largeTitle, weight: .bold).lineLimit(1)
                Text("\(pileCount.counted("batch", plural: "batches")) · \(frameCount.counted("frame"))").metaStyle(.caption)
            }
            Spacer(minLength: 8)
            Button(action: onNewPile) {
                Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.strewnAccent, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            }
            .accessibilityLabel("New batch")
            Button(action: onAccount) { AvatarView(user: user, size: 44) }
                .accessibilityLabel("Account")
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// What an empty desk says, instead of a blank mat.
private struct EmptyDesk: View {
    var onNewPile: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Your desk is clear").titleStyle(.title3)
            Text("Make a batch from photos in your library.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("New batch", systemImage: "plus", action: onNewPile)
                .buttonStyle(.borderedProminent).tint(.strewnAccent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.top, 24)
    }
}

/// Your account, set out on the desk like a contact sheet: who you are, what you've made,
/// your latest frames, and signing out.
struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var frameCount: Int { model.myCollections.reduce(0) { $0 + $1.photos.count } }
    private var recentCovers: [Photo] { model.myCollections.compactMap(\.cover).prefix(4).map { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let me = model.me {
                        VStack(spacing: 6) {
                            AvatarView(user: me, size: 92)
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                                .padding(.bottom, 6)
                            Text(me.displayName).titleStyle(.title, weight: .bold)
                            Text("@\(me.handle)").metaStyle(.subheadline)
                        }
                        .padding(.top, 8)

                        stats(me)

                        if !recentCovers.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                label("Latest batches")
                                HStack(spacing: 12) {
                                    ForEach(Array(recentCovers.enumerated()), id: \.element.id) { index, photo in
                                        PrintView(photo: photo, paper: 3)
                                            .aspectRatio(1, contentMode: .fit)
                                            .clipped()
                                            .rotationEffect(.degrees([-3, 2, -1.5, 3][index]))
                                    }
                                    ForEach(recentCovers.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                                }
                            }
                        }

                        VStack(spacing: 0) {
                            NavigationLink { ProfileView(user: me) } label: {
                                row("Your desk as friends see it", systemImage: "person.crop.rectangle")
                            }
                            Divider().padding(.leading, 48)
                            NavigationLink { BlockedPeopleView() } label: {
                                row("Blocked", systemImage: "hand.raised", detail: model.blocked.isEmpty ? nil : "\(model.blocked.count)")
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))

                        if AppLinks.feedbackMail() != nil || AppLinks.privacyPolicy != nil {
                            VStack(spacing: 0) {
                                if let mail = AppLinks.feedbackMail() {
                                    Link(destination: mail) { row("Send feedback", systemImage: "envelope", chevron: false) }
                                }
                                if AppLinks.feedbackMail() != nil && AppLinks.privacyPolicy != nil {
                                    Divider().padding(.leading, 48)
                                }
                                if let policy = AppLinks.privacyPolicy {
                                    Link(destination: policy) { row("Privacy policy", systemImage: "hand.raised.square", chevron: false) }
                                }
                            }
                            .buttonStyle(.plain)
                            .background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                        }

                        VStack(spacing: 0) {
                            Button { dismiss(); Task { await model.signOut() } } label: {
                                row("Sign out", systemImage: "rectangle.portrait.and.arrow.right", tint: .red, chevron: false)
                            }
                            Divider().padding(.leading, 48)
                            NavigationLink { DeleteAccountView() } label: {
                                row("Delete account", systemImage: "trash", tint: .red)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    }

                    if model.isDemo {
                        Label("Demo mode: sample friends, and nothing leaves this phone. Batches reset when the app restarts.",
                              systemImage: "testtube.2")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(Self.versionLine).metaStyle().frame(maxWidth: .infinity).padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(DeskMatBackground())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.strewnAccent)
    }

    /// Counts in a strip like film edge printing: big number, small label, hairline between.
    private func stats(_ me: User) -> some View {
        HStack(spacing: 0) {
            stat(model.myCollections.count, "batch", "batches")
            Divider().frame(height: 34)
            stat(frameCount, "frame", "frames")
            Divider().frame(height: 34)
            stat(me.followerCount, "follower", "followers")
            Divider().frame(height: 34)
            stat(me.followingCount, "following", "following")
        }
        .padding(.vertical, 14)
        .background(Color.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ value: Int, _ one: String, _ many: String) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(.system(.title2, design: .serif, weight: .semibold)).monospacedDigit()
            Text((value == 1 ? one : many).uppercased()).font(.system(size: 9.5, weight: .medium, design: .monospaced)).kerning(0.8).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, systemImage: String, tint: Color = .primary, detail: String? = nil, chevron: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage).frame(width: 22).foregroundStyle(tint == .primary ? Color.strewnAccent : tint)
            Text(title).foregroundStyle(tint)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Batches \(version) (\(build))"
    }
}

/// Identifies a pile for `.sheet(item:)`.
struct PileRef: Identifiable, Hashable { let id: UUID }
