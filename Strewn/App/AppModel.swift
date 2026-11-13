import SwiftUI

/// App-wide state: who is signed in, their piles, who they follow and the friends feed.
@MainActor
@Observable
final class AppModel {
    enum AuthState: Equatable { case loading, signedOut, needsProfile, signedIn }

    private(set) var auth = AuthState.loading
    private(set) var me: User?
    var myCollections: [PhotoCollection] = []
    var feed: [PhotoCollection] = []
    /// Ids of the people you follow.
    private(set) var following: Set<UUID> = []
    /// People you've blocked, for the list in your account where you can unblock them.
    private(set) var blocked: [User] = []
    /// How you've arranged your desk. Kept on this phone too, so it's there straight away.
    private(set) var desk = DeskLayout()
    /// Likes and comments added up per batch, for your shared batches and the feed.
    private(set) var batchTotals: [UUID: PhotoReactions] = [:]
    /// Likes and comments other people left on your photos, newest first.
    private(set) var activity: [ActivityItem] = []
    /// Activity newer than this hasn't been looked at yet.
    private(set) var activitySeenAt = Date.distantPast
    /// A pile opened from a strewn://pile link.
    var linkedPile: PhotoCollection?
    /// The photo a strewn://pile link pointed at, opened inside linkedPile.
    var linkedPhotoID: UUID?
    var errorMessage: String?

    private let backend: Backend
    @ObservationIgnored private let local = LocalLibrary()
    /// Goes up with every change to the desk, so a slower load can't undo a newer change.
    @ObservationIgnored private var deskRevision = 0
    @ObservationIgnored private var deskLoadedFor: UUID?

    init(backend: Backend) { self.backend = backend }

    static func makeBackend() -> Backend {
        // Use the demo backend until real Supabase settings are in Config.xcconfig.
        if let config = SupabaseBackend.Config.fromInfoPlist() { return SupabaseBackend(config: config) }
        return MockBackend()
    }

    /// True when running without a server: sample people, nothing leaves the phone.
    var isDemo: Bool { backend is MockBackend }

    /// Sign in with Apple needs a paid developer team and the Apple provider set up in Supabase,
    /// so it stays hidden until APPLE_SIGN_IN = YES in Config.xcconfig.
    var appleSignInEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "StrewnAppleSignIn") as? String)?.uppercased() == "YES"
    }

    // MARK: Account

    func load() async {
        guard let id = await backend.restoreSession() else { auth = .signedOut; return }
        await finishSignIn(id)
    }

    func sendSignInCode(to email: String) async throws {
        try await backend.sendSignInCode(to: email)
    }

    func verifySignInCode(email: String, code: String) async throws {
        let id = try await backend.verifySignInCode(email: email, code: code)
        await finishSignIn(id)
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let id = try await backend.signInWithApple(idToken: idToken, nonce: nonce)
        await finishSignIn(id)
    }

    /// The App Review account signs in with a password; nobody else has one.
    func signIn(email: String, password: String) async throws {
        let id = try await backend.signIn(email: email, password: password)
        await finishSignIn(id)
    }

    func isHandleAvailable(_ handle: String) async -> Bool {
        (try? await backend.isHandleAvailable(handle)) ?? true
    }

    func createProfile(handle: String, displayName: String) async throws {
        me = try await backend.createProfile(handle: handle, displayName: displayName)
        auth = .signedIn
        await refresh()
    }

    func signOut() async {
        try? await backend.signOut()
        clearSession()
    }

    /// Deletes the account on the server, then forgets this phone's record of shared photos.
    /// The photos themselves stay in the Photos library.
    func deleteAccount() async throws {
        try await backend.deleteAccount()
        local.forget((myCollections + feed).flatMap(\.photos).map(\.id))
        if let me { Self.forgetDesk(of: me.id) }
        clearSession()
    }

    private func clearSession() {
        Task { await PhotoImageLoader.shared.forgetEverything() }
        me = nil
        myCollections = []
        feed = []
        following = []
        blocked = []
        batchTotals = [:]
        activity = []
        activitySeenAt = .distantPast
        desk = DeskLayout()
        deskLoadedFor = nil
        auth = .signedOut
    }

    private func finishSignIn(_ id: UUID) async {
        do {
            guard let user = try await backend.profile(id: id) else { auth = .needsProfile; return }
            me = user
            activitySeenAt = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.activityKey(user.id)))
            auth = .signedIn
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            auth = .signedOut
        }
    }

    /// Reloads your piles, who you follow and the feed.
    func refresh() async {
        guard let me else { return }
        // Alongside the rest, so a slow desk doesn't hold up the feed.
        async let deskLoaded: Void = refreshDesk(for: me.id)
        do {
            async let mine = backend.collections(ownedBy: me.id)
            async let friends = backend.feed()
            async let follows = backend.following(me.id)
            async let profile = backend.profile(id: me.id)
            async let blocks = backend.blocked()
            let (m, f, fl, p) = try await (mine, friends, follows, profile)
            blocked = (try? await blocks) ?? blocked
            myCollections = local.merge(m)
            // Photos you added to friends' piles show from this phone's files too.
            feed = local.merge(f)
            following = Set(fl.map(\.id))
            if let p { self.me = p }
        } catch {
            errorMessage = error.localizedDescription
        }
        await deskLoaded
        await refreshSocial()
    }

    // MARK: Activity

    var unseenActivity: [ActivityItem] { activity.filter { $0.at > activitySeenAt } }

    /// Reloads the like and comment totals for batches, and what people did to your photos.
    /// Quietly keeps what it had if the server can't be reached or doesn't have the tables yet.
    func refreshSocial() async {
        guard let me else { return }
        let shared = myCollections.filter(\.isShared)
        let piles = shared + feed
        var byPhoto: [UUID: PhotoReactions] = [:]
        // In chunks: the ids travel in the request's address, which has a length limit.
        for chunk in piles.flatMap({ $0.photos.map(\.id) }).chunked(100) {
            guard let part = try? await backend.reactions(to: chunk) else { return }
            byPhoto.merge(part) { _, new in new }
        }
        var totals: [UUID: PhotoReactions] = [:]
        for pile in piles {
            var sum = PhotoReactions()
            for photo in pile.photos {
                guard let one = byPhoto[photo.id] else { continue }
                sum.likeCount += one.likeCount
                sum.commentCount += one.commentCount
                sum.likedByMe = sum.likedByMe || one.likedByMe
            }
            totals[pile.id] = sum
        }
        batchTotals = totals

        // Your photos: everything in your shared batches, and what you added to friends' batches.
        let mine = shared.flatMap { $0.photos.map(\.id) } + feed.flatMap { $0.photos.filter { $0.addedBy == me.id }.map(\.id) }
        let hidden = Set(blocked.map(\.id))
        var items: [ActivityItem] = []
        for chunk in mine.chunked(100) {
            guard let part = try? await backend.activity(on: chunk, limit: 40) else { return }
            items += part
        }
        activity = Array(items.filter { !hidden.contains($0.actorID) }.sorted { $0.at > $1.at }.prefix(60))
    }

    func markActivitySeen() {
        guard let me, !unseenActivity.isEmpty else { return }
        activitySeenAt = .now
        UserDefaults.standard.set(activitySeenAt.timeIntervalSince1970, forKey: Self.activityKey(me.id))
    }

    /// The batch a photo is in, among yours and the feed's.
    func batch(containing photoID: UUID) -> PhotoCollection? {
        (myCollections + feed).first { $0.photos.contains { $0.id == photoID } }
    }

    private static func activityKey(_ id: UUID) -> String { "strewn.activitySeen.\(id.uuidString.lowercased())" }

    // MARK: People

    func search(_ query: String) async -> [User] {
        let ids = Set(blocked.map(\.id))
        return ((try? await backend.searchProfiles(query)) ?? []).filter { !ids.contains($0.id) }
    }

    func profile(_ id: UUID) async -> User? {
        try? await backend.profile(id: id)
    }

    /// Piles of someone else that you're allowed to see.
    func piles(of user: User) async -> [PhotoCollection] {
        (try? await backend.collections(ownedBy: user.id)) ?? []
    }

    func isFollowing(_ user: User) -> Bool { following.contains(user.id) }

    func toggleFollow(_ user: User) async {
        let wasFollowing = following.contains(user.id)
        if wasFollowing { following.remove(user.id) } else { following.insert(user.id) }
        do {
            if wasFollowing { try await backend.unfollow(user.id) } else { try await backend.follow(user.id) }
            await refresh()
        } catch {
            if wasFollowing { following.insert(user.id) } else { following.remove(user.id) }
            errorMessage = error.localizedDescription
        }
    }

    /// Who follows this person, by handle.
    func followers(of user: User) async throws -> [User] {
        let ids = Set(blocked.map(\.id))
        return try await backend.followers(user.id).filter { !ids.contains($0.id) }.sorted { $0.handle < $1.handle }
    }

    /// Who this person follows, by handle.
    func following(of user: User) async throws -> [User] {
        let ids = Set(blocked.map(\.id))
        return try await backend.following(user.id).filter { !ids.contains($0.id) }.sorted { $0.handle < $1.handle }
    }

    // MARK: Your desk

    /// Changes the desk. Pass save: false while a drag is still going; `saveDesk` ends it.
    func changeDesk(save: Bool = true, _ change: (inout DeskLayout) -> Void) {
        // On a copy: callers read the desk's tiles from inside `change`, and that read would
        // overlap a direct inout access to `desk`, which traps at runtime.
        var next = desk
        change(&next)
        desk = next
        deskRevision += 1
        if save { saveDesk() }
    }

    /// Keeps the desk on this phone and sends it to your account. If that fails (no signal), the
    /// change is marked unsent and goes up with the next refresh instead of being overwritten.
    func saveDesk() {
        guard let me else { return }
        desk = desk.normalized(keeping: myCollections)
        let layout = desk
        Self.storeDesk(layout, unsent: true, for: me.id)
        let revision = deskRevision
        Task {
            guard (try? await backend.saveDeskLayout(layout)) != nil, revision == deskRevision else { return }
            Self.storeDesk(layout, unsent: false, for: me.id)
        }
    }

    private func refreshDesk(for id: UUID) async {
        if deskLoadedFor != id {
            deskLoadedFor = id
            if let stored = Self.storedDesk(of: id) { desk = stored.layout }
        }
        if Self.storedDesk(of: id)?.unsent == true {
            let layout = desk
            if (try? await backend.saveDeskLayout(layout)) != nil { Self.storeDesk(layout, unsent: false, for: id) }
            return
        }
        let revision = deskRevision
        guard let remote = try? await backend.deskLayout(), revision == deskRevision else { return }
        desk = remote
        Self.storeDesk(remote, unsent: false, for: id)
    }

    private struct StoredDesk: Codable { var layout: DeskLayout; var unsent: Bool }
    private static func deskKey(_ id: UUID) -> String { "strewn.desk.\(id.uuidString.lowercased())" }

    private static func storedDesk(of id: UUID) -> StoredDesk? {
        UserDefaults.standard.data(forKey: deskKey(id)).flatMap { try? JSONDecoder().decode(StoredDesk.self, from: $0) }
    }

    private static func storeDesk(_ layout: DeskLayout, unsent: Bool, for id: UUID) {
        if let data = try? JSONEncoder().encode(StoredDesk(layout: layout, unsent: unsent)) {
            UserDefaults.standard.set(data, forKey: deskKey(id))
        }
    }

    private static func forgetDesk(of id: UUID) {
        UserDefaults.standard.removeObject(forKey: deskKey(id))
    }

    // MARK: Safety

    func isBlocked(_ user: User) -> Bool { blocked.contains { $0.id == user.id } }

    /// Blocks someone: neither of you sees the other's batches, follows between you end and
    /// batches shared between you stop being shared.
    func block(_ user: User) async {
        do {
            try await backend.block(user.id)
            if !isBlocked(user) { blocked.append(user) }
            following.remove(user.id)
            await refresh()
        } catch {
            errorMessage = "Couldn't block @\(user.handle): \(error.localizedDescription)"
        }
    }

    func unblock(_ user: User) async {
        do {
            try await backend.unblock(user.id)
            blocked.removeAll { $0.id == user.id }
            await refresh()
        } catch {
            errorMessage = "Couldn't unblock @\(user.handle): \(error.localizedDescription)"
        }
    }

    func report(_ report: Report) async throws {
        try await backend.report(report)
    }

    // MARK: Sharing

    /// Sets who can see a pile. Sharing uploads small copies of each photo (never the RAW);
    /// making a pile private again keeps them until the pile is deleted, but nobody else can open them.
    func setSharing(_ visibility: PhotoCollection.Visibility, people: [User], canAdd: Set<UUID>, for collectionID: UUID) async {
        let canAdd = canAdd.intersection(people.map(\.id))
        update(collectionID) {
            $0.visibility = visibility
            $0.sharedWith = people
            $0.contributorIDs = canAdd
        }
        do {
            try await backend.setSharedWith(people.map(\.id), canAdd: canAdd, collectionID: collectionID)
            // Copies upload in the background; the pile shows for others as each one lands.
            if visibility != .private { Task { await publishCopies(for: collectionID) } }
        } catch {
            errorMessage = "Couldn't update sharing: \(error.localizedDescription)"
        }
    }

    /// Uploads shared copies for photos in a shared pile that don't have current ones.
    func publishCopies(for collectionID: UUID) async {
        guard let pile = myCollections.first(where: { $0.id == collectionID }), pile.isShared else { return }
        var failed = 0
        for photo in pile.photos where photo.sharePath == nil && photo.imageURL.isFileURL {
            do {
                let url = photo.imageURL
                let copies = try await Task.detached(priority: .utility) { try ShareCopyMaker.make(from: url) }.value
                let path = try await backend.publish(copies, photoID: photo.id, replacing: nil)
                guard let found = indices(photo.id, in: collectionID) else { continue }
                myCollections[found.0].photos[found.1].sharePath = path
            } catch {
                failed += 1
            }
        }
        if let pile = myCollections.first(where: { $0.id == collectionID }) { persist(pile) }
        if failed > 0 { errorMessage = "\(failed) photo\(failed == 1 ? "" : "s") couldn't be shared. Try again from Share." }
    }

    /// Opens batch links (https://batches.space/b/<id>[?photo=<id>], and the older
    /// strewn://pile/<id> form), strewn://u/<handle> links, and the sign-in link from the email.
    func open(_ url: URL) async {
        if let web = Self.appLink(fromWeb: url) { return await open(web) }
        guard url.scheme == "strewn" else { return }
        if url.host() == "auth-callback" {
            guard auth == .signedOut else { return }
            do {
                await finishSignIn(try await backend.signIn(fromLink: url))
            } catch {
                errorMessage = "That sign-in link didn't work. It may have expired or been used already; ask for a new one."
            }
            return
        }
        guard auth == .signedIn else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "pile":
            guard let id = parts.first.flatMap(UUID.init(uuidString:)) else { return }
            if let pile = try? await backend.collection(id: id) {
                linkedPhotoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "photo" }?.value.flatMap(UUID.init(uuidString:))
                linkedPile = pile
            } else {
                errorMessage = "That batch is private or was deleted."
            }
        default:
            break
        }
    }

    /// A web link, so Messages and other apps show it as a link with a preview. With the app
    /// installed, iOS opens it here (applinks:batches.space); without, it opens a page on
    /// batches.space that never shows the batch itself.
    static func link(to pile: PhotoCollection) -> URL {
        URL(string: "https://\(webHost)/b/\(pile.id.uuidString.lowercased())")!
    }

    /// Opens the batch in the app and then this photo in it.
    static func link(to pile: PhotoCollection, photo: Photo) -> URL {
        URL(string: "https://\(webHost)/b/\(pile.id.uuidString.lowercased())?photo=\(photo.id.uuidString.lowercased())")!
    }

    static let webHost = "batches.space"

    /// https://batches.space/b/<id>[?photo=<id>] as the strewn://pile link the rest of open(_:) reads.
    static func appLink(fromWeb url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host(), host == webHost || host == "www.\(webHost)" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "b", let id = UUID(uuidString: parts[1]) else { return nil }
        var app = URLComponents()
        app.scheme = "strewn"
        app.host = "pile"
        app.path = "/" + id.uuidString.lowercased()
        let photo = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "photo" }?.value.flatMap(UUID.init(uuidString:))
        if let photo { app.queryItems = [URLQueryItem(name: "photo", value: photo.uuidString.lowercased())] }
        return app.url
    }

    func setCover(_ photo: Photo, in collectionID: UUID) {
        update(collectionID) { $0.coverPhotoID = photo.id }
    }

    func setFrame(_ frame: FrameStyle, for collectionID: UUID) {
        update(collectionID) { $0.frame = frame }
    }

    /// The short note under the title. Empty clears it.
    func setDescription(_ text: String, for collectionID: UUID) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PhotoCollection.descriptionLimit))
        update(collectionID) { $0.description = trimmed }
    }

    /// Sets the background, and the nearest wall builds 7 and 8 understand, so they show something close.
    func setBackground(_ background: BatchBackground, for collectionID: UUID) {
        update(collectionID) { pile in
            pile.background = background
            pile.frame.wall = background.legacyWall
        }
    }

    // MARK: Photo likes and comments

    /// Likes and comment counts for a batch's photos, or nil if they can't be loaded (no signal,
    /// or a server without the photo tables yet). Callers hide the controls then.
    func reactions(for photos: [Photo]) async -> [UUID: PhotoReactions]? {
        try? await backend.reactions(to: photos.map(\.id))
    }

    func setLiked(_ liked: Bool, photoID: UUID) async throws {
        try await backend.setLiked(liked, photoID: photoID)
    }

    func comments(on photoID: UUID) async throws -> [PhotoComment] {
        let hidden = Set(blocked.map(\.id))
        return try await backend.comments(on: photoID).filter { !hidden.contains($0.authorID) }
    }

    func addComment(_ body: String, to photoID: UUID) async throws -> PhotoComment {
        guard let me else { throw BackendError.notSignedIn }
        let text = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PhotoComment.maxLength))
        let comment = PhotoComment(id: UUID(), photoID: photoID, author: me, authorID: me.id, body: text, createdAt: .now)
        try await backend.addComment(id: comment.id, body: text, photoID: photoID)
        return comment
    }

    func deleteComment(_ comment: PhotoComment) async throws {
        try await backend.deleteComment(comment.id)
    }

    func setFont(_ font: BatchFont, for collectionID: UUID) {
        update(collectionID) { $0.font = font }
    }

    /// Replaces where a batch's photos sit on its board, and opens the batch as a board.
    func setBoard(_ placements: [UUID: BatchBoard.Placement], for collectionID: UUID) {
        update(collectionID) { pile in
            pile.board = BatchBoard(isOn: true, placements: Dictionary(uniqueKeysWithValues: placements.map { (BatchBoard.key($0.key), $0.value) }))
        }
    }

    /// Turns the board layout on or off. Its arrangement is kept either way.
    func setBoardOn(_ isOn: Bool, for collectionID: UUID) {
        update(collectionID) { pile in
            var board = pile.board ?? BatchBoard()
            board.isOn = isOn
            pile.board = board
        }
    }

    func rename(_ collectionID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(collectionID) { $0.title = title }
    }

    /// Moves photos within a pile and renumbers every position, so the saved order matches.
    func movePhotos(in collectionID: UUID, from source: IndexSet, to destination: Int) {
        update(collectionID) { pile in
            pile.photos.move(fromOffsets: source, toOffset: destination)
            for i in pile.photos.indices { pile.photos[i].sortIndex = i }
        }
    }

    /// Adds a freshly developed shot to today's pile, creating it if needed.
    func addToTodaysRoll(_ photo: Photo) {
        local.remember(photo)
        if let i = myCollections.firstIndex(where: { $0.title == "Today's roll" && Calendar.current.isDateInToday($0.shotOn ?? .distantPast) }) {
            myCollections[i].photos.append(photo)
            persist(myCollections[i])
            if myCollections[i].isShared {
                let id = myCollections[i].id
                Task { await publishCopies(for: id) }
            }
        } else if let me {
            var roll = PhotoCollection(id: photo.collectionID, ownerID: me.id, title: "Today's roll", place: nil,
                                       shotOn: .now, photos: [photo], coverPhotoID: photo.id, frame: FrameStyle())
            roll.visibility = .private
            myCollections.insert(roll, at: 0)
            persist(roll)
        }
    }

    // MARK: Piles

    func createPile(title: String, photos: [Photo], frame: FrameStyle) {
        guard let me, let first = photos.first else { return }
        let id = first.collectionID
        let pile = PhotoCollection(id: id, ownerID: me.id, title: title, place: nil, shotOn: photos.compactMap(\.capturedAt).min() ?? .now,
                                   photos: photos, coverPhotoID: first.id, frame: frame)
        photos.forEach(local.remember)
        myCollections.insert(pile, at: 0)
        persist(pile)
    }

    /// Adds imported photos to the end of one of your piles.
    func addPhotos(_ photos: [Photo], to collectionID: UUID) {
        guard let c = myCollections.firstIndex(where: { $0.id == collectionID }), !photos.isEmpty else { return }
        let next = (myCollections[c].photos.map(\.sortIndex).max() ?? -1) + 1
        let added = photos.enumerated().map { i, photo in
            var photo = photo
            photo.collectionID = collectionID
            photo.sortIndex = next + i
            return photo
        }
        added.forEach(local.remember)
        myCollections[c].photos += added
        if myCollections[c].coverPhotoID == nil { myCollections[c].coverPhotoID = added.first?.id }
        persist(myCollections[c])
        if myCollections[c].isShared { Task { await publishCopies(for: collectionID) } }
    }

    /// Takes photos out of a pile (and its shared copies off the server). The files stay on
    /// this phone and in Photos; only the pile forgets them.
    func removePhotos(_ ids: Set<UUID>, from collectionID: UUID) {
        guard let c = myCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        let before = myCollections[c]
        myCollections[c].photos.removeAll { ids.contains($0.id) }
        if let cover = myCollections[c].coverPhotoID, ids.contains(cover) {
            myCollections[c].coverPhotoID = myCollections[c].photos.first?.id
        }
        let after = myCollections[c]
        Task {
            do {
                try await backend.deletePhotos(Array(ids), from: collectionID)
                try await backend.save(after)
                local.forget(Array(ids))
            } catch {
                if let i = myCollections.firstIndex(where: { $0.id == collectionID }) { myCollections[i] = before }
                errorMessage = "Couldn't remove the photo: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Group piles

    /// Adds your photos to a friend's pile that lets you. Each photo's shared copies upload
    /// first, since nobody else has the files; the photos then join the pile as yours.
    func contribute(_ photos: [Photo], to collectionID: UUID) async {
        guard let me, let f = feed.firstIndex(where: { $0.id == collectionID }), feed[f].canAdd, !photos.isEmpty else { return }
        let next = (feed[f].photos.map(\.sortIndex).max() ?? -1) + 1
        var ready: [Photo] = []
        for (i, photo) in photos.enumerated() {
            var photo = photo
            photo.collectionID = collectionID
            photo.sortIndex = next + i
            photo.addedBy = me.id
            do {
                let url = photo.imageURL
                let copies = try await Task.detached(priority: .userInitiated) { try ShareCopyMaker.make(from: url) }.value
                photo.sharePath = try await backend.publish(copies, photoID: photo.id, replacing: nil)
                local.remember(photo)
                ready.append(photo)
            } catch {
                continue
            }
        }
        if ready.count < photos.count {
            let failed = photos.count - ready.count
            errorMessage = "\(failed.counted("photo")) couldn't be uploaded."
        }
        guard !ready.isEmpty else { return }
        do {
            try await backend.contribute(ready, to: collectionID)
            if let f = feed.firstIndex(where: { $0.id == collectionID }) {
                feed[f].photos += ready
                if !feed[f].contributors.contains(where: { $0.id == me.id }) { feed[f].contributors.append(me) }
            }
        } catch {
            errorMessage = "Couldn't add to the batch: \(error.localizedDescription)"
        }
    }

    /// Takes photos you added out of a friend's pile.
    func removeContributed(_ ids: Set<UUID>, from collectionID: UUID) {
        guard let f = feed.firstIndex(where: { $0.id == collectionID }) else { return }
        let before = feed[f]
        feed[f].photos.removeAll { ids.contains($0.id) }
        Task {
            do {
                try await backend.deletePhotos(Array(ids), from: collectionID)
            } catch {
                if let i = feed.firstIndex(where: { $0.id == collectionID }) { feed[i] = before }
                errorMessage = "Couldn't remove the photo: \(error.localizedDescription)"
            }
        }
    }

    func deletePile(_ id: UUID) {
        guard let pile = myCollections.first(where: { $0.id == id }) else { return }
        myCollections.removeAll { $0.id == id }
        Task {
            do {
                try await backend.deleteCollection(id)
                local.forget(pile.photos.map(\.id))
            } catch {
                myCollections.append(pile)
                errorMessage = "Couldn't delete the batch: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Editing

    // Built on first edit, not at launch, so the desk opens even if the color pipeline can't load.
    @ObservationIgnored private lazy var editRenderer = EditRenderer()

    /// Renders the edit at full resolution, stores it next to the untouched original, and
    /// mirrors it into Photos as a revertible edit when the photo came from the library.
    func saveEdit(_ recipe: EditRecipe, photoID: UUID, collectionID: UUID) async {
        guard let found = indices(photoID, in: collectionID) else { return }
        let (c, p) = found
        var photo = myCollections[c].photos[p]
        do {
            try await render(recipe, into: &photo)
            if let assetID = photo.photosAssetID {
                let data = try Data(contentsOf: photo.imageURL)
                try await PhotosEditSaver.saveRevertibleEdit(assetID: assetID, rendered: data, recipe: recipe)
            }
            myCollections[c].photos[p] = photo
            persist(myCollections[c])
            local.remember(photo)
            if myCollections[c].isShared { await republish(photoID: photo.id, in: collectionID) }
        } catch {
            errorMessage = "Couldn't save the edit: \(error.localizedDescription)"
        }
    }

    /// Paste a recipe onto every photo in a pile. Each photo keeps its own crop.
    func applyEdits(_ recipe: EditRecipe, toPile collectionID: UUID, except skipID: UUID? = nil) async {
        guard let c = myCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        var edited: [UUID] = []
        for p in myCollections[c].photos.indices where myCollections[c].photos[p].id != skipID {
            var photo = myCollections[c].photos[p]
            let merged = (photo.edit ?? .identity).pasting(recipe)
            do {
                try await render(merged, into: &photo)
                myCollections[c].photos[p] = photo
                local.remember(photo)
                edited.append(photo.id)
            } catch {
                errorMessage = "Some photos couldn't be updated: \(error.localizedDescription)"
            }
        }
        persist(myCollections[c])
        if myCollections[c].isShared {
            for id in edited { await republish(photoID: id, in: collectionID) }
        }
    }

    /// After an edit, replaces the photo's shared copies so viewers see the new look.
    private func republish(photoID: UUID, in collectionID: UUID) async {
        guard let found = indices(photoID, in: collectionID) else { return }
        let photo = myCollections[found.0].photos[found.1]
        do {
            let url = photo.imageURL
            let copies = try await Task.detached(priority: .utility) { try ShareCopyMaker.make(from: url) }.value
            let path = try await backend.publish(copies, photoID: photo.id, replacing: photo.sharePath)
            guard let now = indices(photoID, in: collectionID) else { return }
            myCollections[now.0].photos[now.1].sharePath = path
            persist(myCollections[now.0])
        } catch {
            errorMessage = "The edit is saved, but people you share with still see the old version."
        }
    }

    private func render(_ recipe: EditRecipe, into photo: inout Photo) async throws {
        if photo.rawURL == nil, photo.originalURL == nil { photo.originalURL = photo.imageURL }
        if recipe.isIdentity {
            photo.imageURL = photo.originalURL ?? photo.imageURL
            photo.edit = nil
            return
        }
        let source = try await EditRenderer.Source.load(from: photo.editSourceURL)
        let renderer = editRenderer
        let (data, size) = try await Task.detached(priority: .userInitiated) { try renderer.export(source, recipe: recipe) }.value
        let dir = URL.documentsDirectory.appending(path: "Edits", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(photo.id.uuidString)-\(UUID().uuidString.prefix(6)).heic")
        try data.write(to: url)
        photo.imageURL = url
        photo.pixelWidth = Int(size.width)
        photo.pixelHeight = Int(size.height)
        photo.edit = recipe
    }

    private func indices(_ photoID: UUID, in collectionID: UUID) -> (Int, Int)? {
        guard let c = myCollections.firstIndex(where: { $0.id == collectionID }),
              let p = myCollections[c].photos.firstIndex(where: { $0.id == photoID }) else { return nil }
        return (c, p)
    }

    private func update(_ id: UUID, _ change: (inout PhotoCollection) -> Void) {
        guard let i = myCollections.firstIndex(where: { $0.id == id }) else { return }
        change(&myCollections[i])
        persist(myCollections[i])
    }

    private func persist(_ collection: PhotoCollection) {
        Task {
            do { try await backend.save(collection) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
