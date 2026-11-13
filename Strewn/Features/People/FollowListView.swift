import SwiftUI

/// Pushes the lists of who follows someone and who they follow.
struct FollowListRoute: Hashable, Identifiable {
    enum Tab: String, CaseIterable, Identifiable {
        case followers, following
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    let user: User
    var tab: Tab
    var id: String { "\(user.id)-\(tab.rawValue)" }
}

/// Who follows you and who you follow. Each person opens their desk, and can be followed from here.
struct FollowListView: View {
    let user: User
    @Environment(AppModel.self) private var model
    @State private var tab: FollowListRoute.Tab
    @State private var followers: [User]?
    @State private var following: [User]?
    @State private var failed = false

    init(route: FollowListRoute) {
        user = route.user
        _tab = State(initialValue: route.tab)
    }

    private var people: [User]? { tab == .followers ? followers : following }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaperSegmented(selection: $tab, options: FollowListRoute.Tab.allCases.map { (value: $0, title: label($0)) })
                if let people, !people.isEmpty {
                    PaperSection {
                        ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { PaperDivider(inset: 66) }
                            PeopleListRow(user: person)
                        }
                    }
                } else {
                    emptyState.frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(18)
        }
        .background(DeskMatBackground())
        .paperNavigationTitle(user.id == model.me?.id ? "Your people" : "@\(user.handle)")
        .refreshable { await load() }
        .task { await load() }
        // Following or unfollowing someone from a row changes the Following list.
        .onChange(of: model.following) { Task { await load() } }
    }

    @ViewBuilder
    private var emptyState: some View {
        if failed && people == nil {
            ContentUnavailableView {
                Label("Couldn't load this", systemImage: "wifi.slash")
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if people == nil {
            ProgressView()
        } else if people?.isEmpty == true {
            ContentUnavailableView(emptyTitle, systemImage: "person.2", description: Text(emptyDetail))
        }
    }

    private var isMe: Bool { user.id == model.me?.id }

    private var emptyTitle: String {
        switch tab {
        case .followers: isMe ? "No followers yet" : "No followers yet"
        case .following: isMe ? "You're not following anyone" : "Not following anyone"
        }
    }

    private var emptyDetail: String {
        switch tab {
        case .followers: isMe ? "People who follow you show up here." : "People who follow @\(user.handle) show up here."
        case .following: isMe ? "Find friends from the Friends tab." : "People @\(user.handle) follows show up here."
        }
    }

    private func label(_ tab: FollowListRoute.Tab) -> String {
        let list = tab == .followers ? followers : following
        guard let count = list?.count else { return tab.title }
        return "\(tab.title) \(count)"
    }

    private func load() async {
        do {
            async let f = model.followers(of: user)
            async let g = model.following(of: user)
            (followers, following) = try await (f, g)
            failed = false
        } catch {
            failed = true
        }
    }
}
