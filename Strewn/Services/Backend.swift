import Foundation

/// Everything the app needs from the social backend. Views never talk to Supabase directly.
/// Who may see which pile is decided by the backend (row level security in supabase/migrations), so a
/// call like `collections(ownedBy:)` returns only the piles the signed-in person is allowed to see.
protocol Backend: Sendable {
    // Account
    /// The signed-in account from the stored session, if there is one.
    func restoreSession() async -> UUID?
    /// Emails a six-digit sign-in code. Creates the account on first use.
    func sendSignInCode(to email: String) async throws
    func verifySignInCode(email: String, code: String) async throws -> UUID
    /// Finishes sign-in from the link in the same email (strewn://auth-callback?...).
    func signIn(fromLink url: URL) async throws -> UUID
    func signInWithApple(idToken: String, nonce: String) async throws -> UUID
    func signOut() async throws
    /// Signs in with an email and password. Only the App Review account has a password; everyone
    /// else signs in with a code or with Apple.
    func signIn(email: String, password: String) async throws -> UUID
    /// Deletes your account and everything you shared: batches, photos (yours and the ones you
    /// added to friends' batches), their copies, follows and shares. Signs you out.
    func deleteAccount() async throws

    // Profiles
    /// nil when the account exists but hasn't picked a handle yet.
    func profile(id: UUID) async throws -> User?
    func profile(handle: String) async throws -> User?
    func isHandleAvailable(_ handle: String) async throws -> Bool
    func createProfile(handle: String, displayName: String) async throws -> User
    func searchProfiles(_ query: String) async throws -> [User]

    // Following
    func following(_ userID: UUID) async throws -> [User]
    func followers(_ userID: UUID) async throws -> [User]
    func follow(_ userID: UUID) async throws
    func unfollow(_ userID: UUID) async throws

    // Photo likes and comments
    /// Likes and comment counts for these photos, as you may see them.
    func reactions(to photoIDs: [UUID]) async throws -> [UUID: PhotoReactions]
    func setLiked(_ liked: Bool, photoID: UUID) async throws
    func comments(on photoID: UUID) async throws -> [PhotoComment]
    func addComment(id: UUID, body: String, photoID: UUID) async throws
    /// Your own comment, or any comment on a batch you own.
    func deleteComment(_ id: UUID) async throws
    /// Likes and comments other people left on these photos, newest first.
    func activity(on photoIDs: [UUID], limit: Int) async throws -> [ActivityItem]

    // Your desk
    /// How you've arranged your desk, or nil if you never have. Only you can read it.
    func deskLayout() async throws -> DeskLayout?
    func saveDeskLayout(_ layout: DeskLayout) async throws

    // Piles
    func collections(ownedBy userID: UUID) async throws -> [PhotoCollection]
    func collection(id: UUID) async throws -> PhotoCollection?
    /// Piles from people you follow plus piles shared with you directly, newest first.
    func feed() async throws -> [PhotoCollection]
    func save(_ collection: PhotoCollection) async throws
    func deleteCollection(_ id: UUID) async throws
    /// Takes photos out of their pile, with their shared copies. Saving a pile never deletes.
    func deletePhotos(_ ids: [UUID], from collectionID: UUID) async throws
    /// Replaces the list of people a pile is shared with directly. `canAdd` is the subset of
    /// them who may add their own photos (a group pile).
    func setSharedWith(_ userIDs: [UUID], canAdd: Set<UUID>, collectionID: UUID) async throws
    /// Adds photos, as yourself, to someone else's pile that lets you add. Their shared copies
    /// must already be published.
    func contribute(_ photos: [Photo], to collectionID: UUID) async throws

    // Shared copies
    /// Uploads the shared copies of one photo and returns their storage path. RAW never goes here.
    func publish(_ copies: [Photo.ShareTier: Data], photoID: UUID, replacing oldPath: String?) async throws -> String

    // Safety
    /// People you've blocked. Neither of you sees the other's batches or photos.
    func blocked() async throws -> [User]
    func block(_ userID: UUID) async throws
    func unblock(_ userID: UUID) async throws
    func report(_ report: Report) async throws
}

/// Something reported for review: a person, a batch, or one photo in a batch.
struct Report: Sendable {
    enum Reason: String, CaseIterable, Identifiable, Sendable {
        case spam, nudity, harassment, violence, copyright, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .spam: "Spam or scam"
            case .nudity: "Nudity or sexual content"
            case .harassment: "Harassment or hate"
            case .violence: "Violence or self-harm"
            case .copyright: "Someone else's photo"
            case .other: "Something else"
            }
        }
    }

    var userID: UUID? = nil
    var collectionID: UUID? = nil
    var photoID: UUID? = nil
    var commentID: UUID? = nil
    var reason: Reason
    var details: String? = nil
}

enum BackendError: LocalizedError {
    case notSignedIn, handleTaken, wrongCode, wrongPassword, notAllowed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You're signed out. Sign in again to continue."
        case .handleTaken: "That handle is taken."
        case .wrongCode: "That code didn't work. Check the latest email and try again."
        case .wrongPassword: "That email and password don't match."
        case .notAllowed: "You can't change that batch."
        }
    }
}

/// In-memory backend for trying the app without a server. It follows the same visibility rules
/// as the database (see `canView`), so following people and sharing piles behave as they will
/// for real. Any six-digit code signs you in as the sample user. The piles reset on relaunch;
/// the sign-in is remembered, so the demo opens straight to the desk.
actor MockBackend: Backend {
    private static let sessionKey = "strewn.demo.signedIn"
    private var signedIn: UUID? = UserDefaults.standard.string(forKey: sessionKey).flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(signedIn?.uuidString, forKey: Self.sessionKey) }
    }
    private var people: [UUID: User] = Dictionary(uniqueKeysWithValues: SampleData.people.map { ($0.id, $0) })
    private var piles: [UUID: PhotoCollection]
    private var follows: Set<Pair> = Set(SampleData.follows.map { Pair(a: $0.follower, b: $0.followee) })
    private var members: Set<Pair>   // (pile id, person id)
    private var contributors: Set<Pair> = []   // members who may add photos
    private var blocks: Set<Pair> = []   // (blocker, blocked)
    private var desks: [UUID: DeskLayout] = [:]
    // (photo, person). Two likes to start with, so the demo's desk and Activity have something to show.
    private var photoLikes: Set<Pair> = Set(SampleData.collections.first?.photos.prefix(2).enumerated().flatMap { index, photo in
        (index == 0 ? [SampleData.maya, SampleData.theo] : [SampleData.maya]).map { Pair(a: photo.id, b: $0.id) }
    } ?? [])
    private var likeTimes: [Pair: Date] = [:]
    // One comment from Maya, so the demo shows what comments look like and how to report one.
    private var photoComments: [PhotoComment] = SampleData.collections.first?.photos.first.map {
        [PhotoComment(id: UUID(uuidString: "6B1E0C1A-0003-4000-8000-000000000001")!, photoID: $0.id, author: SampleData.maya,
                      authorID: SampleData.maya.id, body: "That light on the water. Which beach was this?",
                      createdAt: .now.addingTimeInterval(-7200))]
    } ?? []

    private struct Pair: Hashable { let a: UUID; let b: UUID }

    init() {
        let all = SampleData.collections + SampleData.friendCollections
        piles = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        members = Set(SampleData.shares.compactMap { share in
            all.first { $0.title == share.title }.map { Pair(a: $0.id, b: share.with) }
        })
        contributors = Set(SampleData.groupShares.compactMap { share in
            all.first { $0.title == share.title }.map { Pair(a: $0.id, b: share.with) }
        })
    }

    // Account

    func restoreSession() async -> UUID? { signedIn }
    func sendSignInCode(to email: String) async throws {}
    func verifySignInCode(email: String, code: String) async throws -> UUID {
        guard code.wholeMatch(of: #/\d{6}/#) != nil else { throw BackendError.wrongCode }
        signedIn = SampleData.me.id
        return SampleData.me.id
    }
    func signIn(fromLink url: URL) async throws -> UUID {
        signedIn = SampleData.me.id
        return SampleData.me.id
    }
    func signInWithApple(idToken: String, nonce: String) async throws -> UUID {
        signedIn = SampleData.me.id
        return SampleData.me.id
    }
    func signOut() async throws { signedIn = nil }
    func signIn(email: String, password: String) async throws -> UUID {
        guard !password.isEmpty else { throw BackendError.wrongCode }
        signedIn = SampleData.me.id
        return SampleData.me.id
    }
    func deleteAccount() async throws {
        let me = try requireMe()
        piles = piles.filter { $0.value.ownerID != me }
        for id in piles.keys { piles[id]?.photos.removeAll { $0.addedBy == me } }
        follows = follows.filter { $0.a != me && $0.b != me }
        members = members.filter { $0.b != me }
        contributors = contributors.filter { $0.b != me }
        blocks = blocks.filter { $0.a != me && $0.b != me }
        desks[me] = nil
        photoLikes = photoLikes.filter { $0.b != me }
        photoComments.removeAll { $0.authorID == me }
        people[me] = nil
        signedIn = nil
    }

    // Profiles

    func profile(id: UUID) async throws -> User? { people[id].map { withCounts($0) } }
    func profile(handle: String) async throws -> User? {
        people.values.first { $0.handle == handle.lowercased() }.map { withCounts($0) }
    }
    func isHandleAvailable(_ handle: String) async throws -> Bool {
        !people.values.contains { $0.handle == handle.lowercased() }
    }
    func createProfile(handle: String, displayName: String) async throws -> User {
        let me = try requireMe()
        guard try await isHandleAvailable(handle) || people[me]?.handle == handle else { throw BackendError.handleTaken }
        let user = User(id: me, handle: handle.lowercased(), displayName: displayName, avatarURL: nil, followerCount: 0, followingCount: 0)
        people[me] = user
        return withCounts(user)
    }
    func searchProfiles(_ query: String) async throws -> [User] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return people.values
            .filter { $0.id != signedIn && (q.isEmpty || $0.handle.hasPrefix(q) || $0.displayName.lowercased().contains(q)) }
            .sorted { $0.handle < $1.handle }
            .map { withCounts($0) }
    }

    // Following

    func following(_ userID: UUID) async throws -> [User] {
        follows.filter { $0.a == userID }.compactMap { people[$0.b] }.map { withCounts($0) }
    }
    func followers(_ userID: UUID) async throws -> [User] {
        follows.filter { $0.b == userID }.compactMap { people[$0.a] }.map { withCounts($0) }
    }
    func follow(_ userID: UUID) async throws {
        let me = try requireMe()
        guard userID != me, !isBlocked(me, userID) else { return }
        follows.insert(Pair(a: me, b: userID))
    }
    func unfollow(_ userID: UUID) async throws {
        let me = try requireMe()
        follows.remove(Pair(a: me, b: userID))
    }

    // Photo likes and comments: the same rules as supabase/migrations/20261112000000.

    func reactions(to photoIDs: [UUID]) async throws -> [UUID: PhotoReactions] {
        let me = try requireMe()
        var result: [UUID: PhotoReactions] = [:]
        for id in photoIDs where canViewPhoto(id) {
            let likers = photoLikes.filter { $0.a == id && ($0.b == me || !isBlocked(me, $0.b)) }
            result[id] = PhotoReactions(likeCount: likers.count, likedByMe: likers.contains { $0.b == me },
                                        commentCount: visibleComments(on: id, for: me).count)
        }
        return result
    }

    func setLiked(_ liked: Bool, photoID: UUID) async throws {
        let me = try requireMe()
        guard canViewPhoto(photoID) else { throw BackendError.notAllowed }
        if liked { photoLikes.insert(Pair(a: photoID, b: me)) } else { photoLikes.remove(Pair(a: photoID, b: me)) }
        likeTimes[Pair(a: photoID, b: me)] = liked ? .now : nil
    }

    func activity(on photoIDs: [UUID], limit: Int) async throws -> [ActivityItem] {
        let me = try requireMe()
        let ids = Set(photoIDs)
        let likes = photoLikes.filter { ids.contains($0.a) && $0.b != me && !isBlocked(me, $0.b) }.map { like in
            ActivityItem(id: "like-\(like.a)-\(like.b)", kind: .like, actor: people[like.b], actorID: like.b, photoID: like.a,
                         at: likeTimes[like] ?? .now.addingTimeInterval(-3600))
        }
        let comments = photoComments.filter { ids.contains($0.photoID) && $0.authorID != me && !isBlocked(me, $0.authorID) }.map {
            ActivityItem(id: "comment-\($0.id)", kind: .comment($0.body), actor: $0.author, actorID: $0.authorID, photoID: $0.photoID, at: $0.createdAt)
        }
        return Array((likes + comments).sorted { $0.at > $1.at }.prefix(limit))
    }

    func comments(on photoID: UUID) async throws -> [PhotoComment] {
        let me = try requireMe()
        guard canViewPhoto(photoID) else { return [] }
        return visibleComments(on: photoID, for: me)
    }

    func addComment(id: UUID, body: String, photoID: UUID) async throws {
        let me = try requireMe()
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canViewPhoto(photoID), !text.isEmpty, text.count <= PhotoComment.maxLength else { throw BackendError.notAllowed }
        photoComments.append(PhotoComment(id: id, photoID: photoID, author: people[me], authorID: me, body: text, createdAt: .now))
    }

    func deleteComment(_ id: UUID) async throws {
        let me = try requireMe()
        guard let comment = photoComments.first(where: { $0.id == id }) else { return }
        let owner = piles.values.first { $0.photos.contains { $0.id == comment.photoID } }?.ownerID
        guard comment.authorID == me || owner == me else { throw BackendError.notAllowed }
        photoComments.removeAll { $0.id == id }
    }

    private func canViewPhoto(_ id: UUID) -> Bool {
        guard let me = signedIn, let pile = piles.values.first(where: { $0.photos.contains { $0.id == id } }),
              canView(pile), let photo = pile.photos.first(where: { $0.id == id }) else { return false }
        return photo.addedBy.map { $0 == me || !isBlocked(me, $0) } ?? true
    }

    private func visibleComments(on photoID: UUID, for me: UUID) -> [PhotoComment] {
        photoComments.filter { $0.photoID == photoID && ($0.authorID == me || !isBlocked(me, $0.authorID)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // Your desk

    func deskLayout() async throws -> DeskLayout? { desks[try requireMe()] }
    func saveDeskLayout(_ layout: DeskLayout) async throws { desks[try requireMe()] = layout }

    // Piles

    func collections(ownedBy userID: UUID) async throws -> [PhotoCollection] {
        piles.values.filter { $0.ownerID == userID && canView($0) }
            .sorted { ($0.shotOn ?? .distantPast) > ($1.shotOn ?? .distantPast) }
            .map { decorated($0) }
    }
    func collection(id: UUID) async throws -> PhotoCollection? {
        piles[id].flatMap { canView($0) ? decorated($0) : nil }
    }
    func feed() async throws -> [PhotoCollection] {
        let me = try requireMe()
        return piles.values
            .filter { pile in
                pile.ownerID != me && canView(pile)
                    && (follows.contains(Pair(a: me, b: pile.ownerID)) || members.contains(Pair(a: pile.id, b: me)))
            }
            .sorted { ($0.shotOn ?? .distantPast) > ($1.shotOn ?? .distantPast) }
            .map { decorated($0) }
    }
    func save(_ collection: PhotoCollection) async throws {
        let me = try requireMe()
        guard collection.ownerID == me, piles[collection.id].map({ $0.ownerID == me }) ?? true else { throw BackendError.notAllowed }
        var stored = collection
        stored.owner = nil
        stored.sharedWith = []
        stored.contributorIDs = []
        stored.contributors = []
        // Who added a photo never changes, as the database's trigger keeps it.
        let before = piles[collection.id]?.photos ?? []
        for i in stored.photos.indices {
            stored.photos[i].addedBy = before.first { $0.id == stored.photos[i].id }?.addedBy ?? stored.photos[i].addedBy
        }
        piles[collection.id] = stored
    }
    func contribute(_ photos: [Photo], to collectionID: UUID) async throws {
        let me = try requireMe()
        guard let pile = piles[collectionID], pile.ownerID != me, contributors.contains(Pair(a: collectionID, b: me)) else {
            throw BackendError.notAllowed
        }
        piles[collectionID]?.photos += photos.map { photo in
            var photo = photo
            photo.addedBy = me
            photo.collectionID = collectionID
            return photo
        }
        if piles[collectionID]?.coverPhotoID == nil { piles[collectionID]?.coverPhotoID = photos.first?.id }
    }
    func deleteCollection(_ id: UUID) async throws {
        let me = try requireMe()
        guard piles[id]?.ownerID == me else { throw BackendError.notAllowed }
        piles[id] = nil
        members = members.filter { $0.a != id }
    }
    func deletePhotos(_ ids: [UUID], from collectionID: UUID) async throws {
        let me = try requireMe()
        guard let pile = piles[collectionID] else { throw BackendError.notAllowed }
        // The owner removes any photo; anyone else only the ones they added.
        let allowed = pile.photos.filter { ids.contains($0.id) && (pile.ownerID == me || $0.addedBy == me) }.map(\.id)
        guard !allowed.isEmpty else { throw BackendError.notAllowed }
        piles[collectionID]?.photos.removeAll { allowed.contains($0.id) }
        if let cover = piles[collectionID]?.coverPhotoID, ids.contains(cover) { piles[collectionID]?.coverPhotoID = nil }
    }
    func setSharedWith(_ userIDs: [UUID], canAdd: Set<UUID>, collectionID: UUID) async throws {
        let me = try requireMe()
        guard piles[collectionID]?.ownerID == me else { throw BackendError.notAllowed }
        members = members.filter { $0.a != collectionID }.union(userIDs.map { Pair(a: collectionID, b: $0) })
        contributors = contributors.filter { $0.a != collectionID }
            .union(userIDs.filter(canAdd.contains).map { Pair(a: collectionID, b: $0) })
    }

    // Shared copies: written to a temp folder so the flow can be tried end to end.

    func publish(_ copies: [Photo.ShareTier: Data], photoID: UUID, replacing oldPath: String?) async throws -> String {
        let me = try requireMe()
        let path = "\(me.uuidString.lowercased())/\(photoID.uuidString.lowercased())/\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appending(path: "media/\(path)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (tier, data) in copies { try data.write(to: dir.appending(path: "\(tier.rawValue).heic")) }
        if let oldPath { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "media/\(oldPath)")) }
        return path
    }

    // Safety: the same rules as supabase/migrations/20261104000000_safety.sql.

    func blocked() async throws -> [User] {
        let me = try requireMe()
        return blocks.filter { $0.a == me }.compactMap { people[$0.b] }.sorted { $0.handle < $1.handle }
    }
    func block(_ userID: UUID) async throws {
        let me = try requireMe()
        guard userID != me else { return }
        blocks.insert(Pair(a: me, b: userID))
        follows = follows.filter { !(($0.a == me && $0.b == userID) || ($0.a == userID && $0.b == me)) }
        let cut = { (pair: Pair) -> Bool in
            guard let owner = self.piles[pair.a]?.ownerID else { return false }
            return (owner == me && pair.b == userID) || (owner == userID && pair.b == me)
        }
        members = members.filter { !cut($0) }
        contributors = contributors.filter { !cut($0) }
    }
    func unblock(_ userID: UUID) async throws {
        let me = try requireMe()
        blocks.remove(Pair(a: me, b: userID))
    }
    func report(_ report: Report) async throws { _ = try requireMe() }

    private func isBlocked(_ me: UUID, _ other: UUID) -> Bool {
        blocks.contains(Pair(a: me, b: other)) || blocks.contains(Pair(a: other, b: me))
    }

    // The same rule as can_view_collection in supabase/migrations.
    private func canView(_ pile: PhotoCollection) -> Bool {
        guard let me = signedIn else { return false }
        if pile.ownerID == me { return true }
        if isBlocked(me, pile.ownerID) { return false }
        switch pile.visibility {
        case .private: return false
        case .public: return true
        case .followers: return follows.contains(Pair(a: me, b: pile.ownerID)) || members.contains(Pair(a: pile.id, b: me))
        case .people: return members.contains(Pair(a: pile.id, b: me))
        }
    }

    private func decorated(_ pile: PhotoCollection) -> PhotoCollection {
        var pile = pile
        if let me = signedIn {
            pile.photos.removeAll { photo in photo.addedBy.map { $0 != me && isBlocked(me, $0) } ?? false }
        }
        pile.owner = people[pile.ownerID].map { withCounts($0) }
        // Only the owner sees who else a pile is shared with.
        pile.sharedWith = pile.ownerID == signedIn ? members.filter { $0.a == pile.id }.compactMap { people[$0.b] } : []
        if pile.ownerID == signedIn {
            pile.contributorIDs = Set(contributors.filter { $0.a == pile.id }.map(\.b))
        } else if let me = signedIn {
            pile.canAdd = contributors.contains(Pair(a: pile.id, b: me))
        }
        pile.contributors = Set(pile.photos.compactMap(\.addedBy)).compactMap { people[$0] }
        return pile
    }

    private func withCounts(_ user: User) -> User {
        var user = user
        user.followerCount = follows.filter { $0.b == user.id }.count
        user.followingCount = follows.filter { $0.a == user.id }.count
        return user
    }

    private func requireMe() throws -> UUID {
        guard let signedIn else { throw BackendError.notSignedIn }
        return signedIn
    }
}
