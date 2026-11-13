import Foundation
import Supabase

/// Supabase-backed implementation. Tables and rules are in supabase/migrations/.
/// Used once SUPABASE_URL and SUPABASE_ANON_KEY are filled in Config.xcconfig; until then the
/// app runs on MockBackend.
///
/// Shared copies go to a private Supabase Storage bucket named "media" for now, as
/// {owner}/{photo}/{rev}/{s|m|l}.heic, and viewers get signed links. docs/storage-plan.md
/// describes the R2 setup that replaces this bucket at scale; only `publish` and the signer set
/// in `init` change when it does. RAW files are never uploaded.
final class SupabaseBackend: Backend, @unchecked Sendable {
    struct Config {
        let url: URL
        let anonKey: String

        static func fromInfoPlist() -> Config? {
            guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
                  let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
                  let url = URL(string: urlString), !urlString.contains("your-project"), key != "replace-me"
            else { return nil }
            return Config(url: url, anonKey: key)
        }
    }

    private let client: SupabaseClient
    private var media: StorageFileApi { client.storage.from("media") }
    /// Every pile query embeds its photos and its owner's profile. collections and photos are
    /// linked twice (photos.collection_id and collections.cover_photo_id), so the photos embed
    /// names its foreign key.
    private let pileSelect = "*, photos!photos_collection_id_fkey(*), owner:profiles!owner_id(*)"

    init(config: Config) {
        let client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
        self.client = client
        // Each result names its own path, and one unsignable path doesn't sink the rest.
        PhotoLinks.signer = { paths in
            let results = try await client.storage.from("media").createSignedURLs(paths: paths, expiresIn: PhotoLinks.lifetime)
            var byPath: [String: URL] = [:]
            for case .success(let path, let url) in results { byPath[path] = url }
            return byPath
        }
    }

    // MARK: Account

    func restoreSession() async -> UUID? {
        try? await client.auth.session.user.id
    }

    /// Where the email's sign-in link sends you. Must be in the project's auth redirect URLs
    /// (additional_redirect_urls in supabase/config.toml).
    static let authCallback = URL(string: "strewn://auth-callback")!

    func sendSignInCode(to email: String) async throws {
        // The email carries a link back to the app, and a six-digit code too once the project's
        // email templates include {{ .Token }} (needs custom SMTP on the free plan, see README).
        try await client.auth.signInWithOTP(email: email, redirectTo: Self.authCallback)
    }

    func signIn(fromLink url: URL) async throws -> UUID {
        try await client.auth.session(from: url).user.id
    }

    func verifySignInCode(email: String, code: String) async throws -> UUID {
        do {
            return try await client.auth.verifyOTP(email: email, token: code, type: .email).user.id
        } catch {
            throw BackendError.wrongCode
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> UUID {
        try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)).user.id
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    func signIn(email: String, password: String) async throws -> UUID {
        do {
            return try await client.auth.signIn(email: email, password: password).user.id
        } catch {
            throw BackendError.wrongPassword
        }
    }

    func deleteAccount() async throws {
        let me = try await myID()
        // Copies first: storage files can't be removed from SQL, and once the account is gone
        // nobody may remove them. Yours are every photo in your batches that you added, plus the
        // ones you added to friends' batches; all of them sit under your own folder.
        let mine: [ShareRow] = try await client.from("photos").select("share_path")
            .like("share_path", pattern: "\(me.uuidString.lowercased())/%").execute().value
        let objects = mine.compactMap(\.share_path).flatMap(Self.objectPaths)
        for chunk in stride(from: 0, to: objects.count, by: 900).map({ Array(objects[$0..<min($0 + 900, objects.count)]) }) {
            _ = try await media.remove(paths: chunk)
        }
        try await client.rpc("delete_account").execute()
        try? await client.auth.signOut(scope: .local)
    }

    private func myID() async throws -> UUID {
        guard let id = try? await client.auth.session.user.id else { throw BackendError.notSignedIn }
        return id
    }

    // MARK: Profiles

    func profile(id: UUID) async throws -> User? {
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("id", value: id.uuidString).limit(1).execute().value
        return rows.first?.model
    }

    func profile(handle: String) async throws -> User? {
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("handle", value: handle.lowercased()).limit(1).execute().value
        return rows.first?.model
    }

    func isHandleAvailable(_ handle: String) async throws -> Bool {
        try await profile(handle: handle) == nil
    }

    func createProfile(handle: String, displayName: String) async throws -> User {
        let me = try await myID()
        // Insert, not upsert: clients can't update a profile's id (see the grants in the first migration).
        do {
            let row: ProfileRow = try await client.from("profiles")
                .insert(NewProfile(id: me, handle: handle.lowercased(), display_name: displayName))
                .select().single().execute().value
            return row.model
        } catch let error as PostgrestError where error.code == "23505" {
            // Unique violation: this account already has a profile (a retried tap), or the handle is taken.
            if let existing = try await profile(id: me) { return existing }
            throw BackendError.handleTaken
        }
    }

    func searchProfiles(_ query: String) async throws -> [User] {
        let me = try await myID()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "")
        var request = client.from("profiles").select().neq("id", value: me.uuidString)
        if !q.isEmpty { request = request.or("handle.ilike.\(q)%,display_name.ilike.%\(q)%") }
        let rows: [ProfileRow] = try await request.order("handle").limit(30).execute().value
        return rows.map(\.model)
    }

    // MARK: Following

    func following(_ userID: UUID) async throws -> [User] {
        let rows: [FollowedRow] = try await client.from("follows")
            .select("profile:profiles!followee_id(*)").eq("follower_id", value: userID.uuidString).execute().value
        return rows.map(\.profile.model)
    }

    func followers(_ userID: UUID) async throws -> [User] {
        let rows: [FollowedRow] = try await client.from("follows")
            .select("profile:profiles!follower_id(*)").eq("followee_id", value: userID.uuidString).execute().value
        return rows.map(\.profile.model)
    }

    func follow(_ userID: UUID) async throws {
        let me = try await myID()
        try await client.from("follows").upsert(FollowRow(follower_id: me, followee_id: userID), ignoreDuplicates: true).execute()
    }

    func unfollow(_ userID: UUID) async throws {
        let me = try await myID()
        try await client.from("follows").delete()
            .eq("follower_id", value: me.uuidString).eq("followee_id", value: userID.uuidString).execute()
    }

    // MARK: Photo likes and comments

    func reactions(to photoIDs: [UUID]) async throws -> [UUID: PhotoReactions] {
        guard !photoIDs.isEmpty else { return [:] }
        let me = try await myID()
        let ids = photoIDs.map(\.uuidString)
        // Row level security leaves out photos you can't see and people across a block.
        async let likeRows: [LikeRow] = client.from("photo_likes").select("photo_id, user_id").in("photo_id", values: ids).execute().value
        async let commentRows: [CommentPhotoRow] = client.from("photo_comments").select("photo_id").in("photo_id", values: ids).execute().value
        let (likes, comments) = try await (likeRows, commentRows)
        var result = Dictionary(uniqueKeysWithValues: photoIDs.map { ($0, PhotoReactions()) })
        for like in likes {
            result[like.photo_id]?.likeCount += 1
            if like.user_id == me { result[like.photo_id]?.likedByMe = true }
        }
        for comment in comments { result[comment.photo_id]?.commentCount += 1 }
        return result
    }

    func setLiked(_ liked: Bool, photoID: UUID) async throws {
        let me = try await myID()
        if liked {
            try await client.from("photo_likes").upsert(LikeRow(photo_id: photoID, user_id: me), ignoreDuplicates: true).execute()
        } else {
            try await client.from("photo_likes").delete().eq("photo_id", value: photoID.uuidString).eq("user_id", value: me.uuidString).execute()
        }
    }

    func comments(on photoID: UUID) async throws -> [PhotoComment] {
        let rows: [CommentRow] = try await client.from("photo_comments")
            .select("id, photo_id, author_id, body, created_at, author:profiles!author_id(*)")
            .eq("photo_id", value: photoID.uuidString).order("created_at").execute().value
        return rows.map(\.model)
    }

    func addComment(id: UUID, body: String, photoID: UUID) async throws {
        let me = try await myID()
        try await client.from("photo_comments").insert(NewComment(id: id, photo_id: photoID, author_id: me, body: body)).execute()
    }

    func deleteComment(_ id: UUID) async throws {
        try await client.from("photo_comments").delete().eq("id", value: id.uuidString).execute()
    }

    func activity(on photoIDs: [UUID], limit: Int) async throws -> [ActivityItem] {
        guard !photoIDs.isEmpty else { return [] }
        let me = try await myID()
        let ids = photoIDs.map(\.uuidString)
        // Row level security leaves out people across a block.
        async let likeRows: [LikeActivityRow] = client.from("photo_likes")
            .select("photo_id, user_id, created_at, liker:profiles!user_id(*)")
            .in("photo_id", values: ids).neq("user_id", value: me.uuidString)
            .order("created_at", ascending: false).limit(limit).execute().value
        async let commentRows: [CommentRow] = client.from("photo_comments")
            .select("id, photo_id, author_id, body, created_at, author:profiles!author_id(*)")
            .in("photo_id", values: ids).neq("author_id", value: me.uuidString)
            .order("created_at", ascending: false).limit(limit).execute().value
        let (likes, comments) = try await (likeRows, commentRows)
        let items = likes.map {
            ActivityItem(id: "like-\($0.photo_id)-\($0.user_id)", kind: .like, actor: $0.liker?.model, actorID: $0.user_id,
                         photoID: $0.photo_id, at: $0.created_at)
        } + comments.map {
            ActivityItem(id: "comment-\($0.id)", kind: .comment($0.body), actor: $0.author?.model, actorID: $0.author_id,
                         photoID: $0.photo_id, at: $0.created_at)
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(limit))
    }

    // MARK: Your desk

    func deskLayout() async throws -> DeskLayout? {
        let me = try await myID()
        let rows: [DeskLayoutRow] = try await client.from("desk_layouts").select("layout")
            .eq("owner_id", value: me.uuidString).limit(1).execute().value
        return rows.first?.layout.value
    }

    func saveDeskLayout(_ layout: DeskLayout) async throws {
        let me = try await myID()
        try await client.from("desk_layouts").upsert(NewDeskLayout(owner_id: me, layout: layout)).execute()
    }

    // MARK: Piles

    func collections(ownedBy userID: UUID) async throws -> [PhotoCollection] {
        // Row level security returns only the piles the signed-in person may see.
        let rows: [CollectionRow] = try await client.from("collections")
            .select(pileSelect)
            .eq("owner_id", value: userID.uuidString)
            .order("shot_on", ascending: false)
            .execute().value
        return try await finish(rows)
    }

    func collection(id: UUID) async throws -> PhotoCollection? {
        let rows: [CollectionRow] = try await client.from("collections").select(pileSelect)
            .eq("id", value: id.uuidString).limit(1).execute().value
        return try await finish(rows).first
    }

    func feed() async throws -> [PhotoCollection] {
        let me = try await myID()
        let followed = try await following(me).map { $0.id.uuidString }
        let shared: [MemberRow] = try await client.from("collection_members")
            .select("collection_id").eq("user_id", value: me.uuidString).execute().value
        var anyOf: [String] = []
        if !followed.isEmpty { anyOf.append("owner_id.in.(\(followed.joined(separator: ",")))") }
        if !shared.isEmpty { anyOf.append("id.in.(\(shared.map { $0.collection_id.uuidString }.joined(separator: ",")))") }
        guard !anyOf.isEmpty else { return [] }
        // Row level security still decides: a followers pile from someone you follow shows,
        // a "specific people" pile only if you're one of them.
        let rows: [CollectionRow] = try await client.from("collections").select(pileSelect)
            .or(anyOf.joined(separator: ","))
            .neq("owner_id", value: me.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute().value
        return try await finish(rows)
    }

    func save(_ collection: PhotoCollection) async throws {
        // Pile first without its cover (the cover must point at a saved photo), then the
        // photos, then the cover.
        var row = CollectionRow(collection)
        row.cover_photo_id = nil
        try await client.from("collections").upsert(row).execute()
        // Your own photos are saved whole. Photos friends added to your pile only get their new
        // position: the database keeps their copies and edits theirs.
        let me = try await myID()
        let own = collection.photos.filter { $0.addedBy == nil || $0.addedBy == me }
        if !own.isEmpty {
            try await client.from("photos").upsert(own.map(PhotoRow.init)).execute()
        }
        for photo in collection.photos where photo.addedBy != nil && photo.addedBy != me {
            try await client.from("photos").update(["sort_index": photo.sortIndex])
                .eq("id", value: photo.id.uuidString).execute()
        }
        if let cover = collection.coverPhotoID {
            try await client.from("collections").update(["cover_photo_id": cover.uuidString])
                .eq("id", value: collection.id.uuidString).execute()
        }
    }

    func deleteCollection(_ id: UUID) async throws {
        let paths: [ShareRow] = try await client.from("photos").select("share_path").eq("collection_id", value: id.uuidString).execute().value
        try await client.from("collections").delete().eq("id", value: id.uuidString).execute()
        let objects = paths.compactMap(\.share_path).flatMap(Self.objectPaths)
        if !objects.isEmpty { _ = try? await media.remove(paths: objects) }
    }

    func deletePhotos(_ ids: [UUID], from collectionID: UUID) async throws {
        guard !ids.isEmpty else { return }
        let idStrings = ids.map(\.uuidString)
        let paths: [ShareRow] = try await client.from("photos").select("share_path").in("id", values: idStrings).execute().value
        // Copies first: removing a friend's copies from your pile is allowed only while their
        // photo is still in it.
        let objects = paths.compactMap(\.share_path).flatMap(Self.objectPaths)
        if !objects.isEmpty { _ = try? await media.remove(paths: objects) }
        // The cover points at photos with on delete set null, so removing the cover is safe.
        try await client.from("photos").delete().in("id", values: idStrings)
            .eq("collection_id", value: collectionID.uuidString).execute()
    }

    func setSharedWith(_ userIDs: [UUID], canAdd: Set<UUID>, collectionID: UUID) async throws {
        try await client.from("collection_members").delete().eq("collection_id", value: collectionID.uuidString).execute()
        if !userIDs.isEmpty {
            try await client.from("collection_members")
                .insert(userIDs.map { MemberInsert(collection_id: collectionID, user_id: $0, can_add: canAdd.contains($0)) }).execute()
        }
    }

    func contribute(_ photos: [Photo], to collectionID: UUID) async throws {
        guard !photos.isEmpty else { return }
        let me = try await myID()
        let rows = photos.map { photo -> PhotoRow in
            var photo = photo
            photo.addedBy = me
            photo.collectionID = collectionID
            return PhotoRow(photo)
        }
        try await client.from("photos").insert(rows).execute()
    }

    // MARK: Shared copies

    func publish(_ copies: [Photo.ShareTier: Data], photoID: UUID, replacing oldPath: String?) async throws -> String {
        let me = try await myID()
        // A new folder per publish, so a cached old copy is never confused with a new edit.
        let path = "\(me.uuidString.lowercased())/\(photoID.uuidString.lowercased())/\(UUID().uuidString.prefix(8).lowercased())"
        for (tier, data) in copies {
            try await media.upload("\(path)/\(tier.rawValue).heic", data: data,
                                   options: FileOptions(cacheControl: "31536000", contentType: "image/heic", upsert: false))
        }
        if let oldPath { _ = try? await media.remove(paths: Self.objectPaths(oldPath)) }
        return path
    }

    // MARK: Safety

    func blocked() async throws -> [User] {
        let me = try await myID()
        let rows: [FollowedRow] = try await client.from("blocks")
            .select("profile:profiles!blocked_id(*)").eq("blocker_id", value: me.uuidString).execute().value
        return rows.map(\.profile.model).sorted { $0.handle < $1.handle }
    }

    func block(_ userID: UUID) async throws {
        let me = try await myID()
        try await client.from("blocks").upsert(BlockRow(blocker_id: me, blocked_id: userID), ignoreDuplicates: true).execute()
    }

    func unblock(_ userID: UUID) async throws {
        let me = try await myID()
        try await client.from("blocks").delete()
            .eq("blocker_id", value: me.uuidString).eq("blocked_id", value: userID.uuidString).execute()
    }

    func report(_ report: Report) async throws {
        // Reports can't be read back, so nothing is returned.
        try await client.from("reports").insert(ReportRow(reported_user_id: report.userID, collection_id: report.collectionID,
                                                           photo_id: report.photoID, comment_id: report.commentID,
                                                           reason: report.reason.rawValue, details: report.details)).execute()
    }

    private static func objectPaths(_ sharePath: String) -> [String] {
        Photo.ShareTier.allCases.map { "\(sharePath)/\($0.rawValue).heic" }
    }

    /// Turns rows into piles: who they're shared with (owner only) and who added each photo.
    /// Links to the shared copies come later, per photo on screen, from PhotoLinks.
    private func finish(_ rows: [CollectionRow]) async throws -> [PhotoCollection] {
        guard !rows.isEmpty else { return [] }
        let me = try? await myID()
        var piles = rows.map(\.model)

        let mine = piles.filter { $0.ownerID == me }.map { $0.id.uuidString }
        if !mine.isEmpty {
            let members: [MemberWithProfile] = try await client.from("collection_members")
                .select("collection_id, can_add, profile:profiles!user_id(*)").in("collection_id", values: mine).execute().value
            for i in piles.indices where piles[i].ownerID == me {
                let shares = members.filter { $0.collection_id == piles[i].id }
                piles[i].sharedWith = shares.map(\.profile.model)
                piles[i].contributorIDs = Set(shares.filter(\.can_add).map(\.profile.id))
            }
        }
        // Piles of other people's that you may add to.
        let theirs = piles.filter { $0.ownerID != me }.map { $0.id.uuidString }
        if let me, !theirs.isEmpty {
            let mineToAdd: [MemberRow] = try await client.from("collection_members").select("collection_id")
                .eq("user_id", value: me.uuidString).eq("can_add", value: true)
                .in("collection_id", values: theirs).execute().value
            let addable = Set(mineToAdd.map(\.collection_id))
            for i in piles.indices where addable.contains(piles[i].id) { piles[i].canAdd = true }
        }
        // Whose each photo is, when a friend added it.
        let adders = Set(piles.flatMap(\.photos).compactMap(\.addedBy)).map(\.uuidString)
        if !adders.isEmpty {
            let profiles: [ProfileRow] = try await client.from("profiles").select().in("id", values: adders).execute().value
            let people = profiles.map(\.model)
            for i in piles.indices {
                let ids = Set(piles[i].photos.compactMap(\.addedBy))
                piles[i].contributors = people.filter { ids.contains($0.id) }
            }
        }
        return piles
    }
}

// MARK: - Row types (snake_case columns)

private struct ProfileRow: Codable {
    let id: UUID; let handle: String; let display_name: String; let avatar_url: URL?
    let follower_count: Int; let following_count: Int
    var model: User { User(id: id, handle: handle, displayName: display_name, avatarURL: avatar_url, followerCount: follower_count, followingCount: following_count) }
}

private struct NewProfile: Encodable { let id: UUID; let handle: String; let display_name: String }
private struct FollowRow: Encodable { let follower_id: UUID; let followee_id: UUID }
private struct FollowedRow: Decodable { let profile: ProfileRow }
private struct MemberRow: Decodable { let collection_id: UUID }
private struct MemberInsert: Encodable { let collection_id: UUID; let user_id: UUID; let can_add: Bool }
private struct MemberWithProfile: Decodable { let collection_id: UUID; let can_add: Bool; let profile: ProfileRow }
private struct ShareRow: Decodable { let share_path: String? }
private struct DeskLayoutRow: Decodable { let layout: Lenient<DeskLayout> }
private struct NewDeskLayout: Encodable { let owner_id: UUID; let layout: DeskLayout }
private struct BlockRow: Encodable { let blocker_id: UUID; let blocked_id: UUID }
private struct ReportRow: Encodable {
    // Nil fields are left out, so reports without a comment still work before the comment migration.
    let reported_user_id: UUID?; let collection_id: UUID?; let photo_id: UUID?; let comment_id: UUID?
    let reason: String; let details: String?
}
private struct LikeRow: Codable { let photo_id: UUID; let user_id: UUID }
private struct CommentPhotoRow: Decodable { let photo_id: UUID }
private struct LikeActivityRow: Decodable { let photo_id: UUID; let user_id: UUID; let created_at: Date; let liker: ProfileRow? }
private struct NewComment: Encodable { let id: UUID; let photo_id: UUID; let author_id: UUID; let body: String }
private struct CommentRow: Decodable {
    let id: UUID; let photo_id: UUID; let author_id: UUID; let body: String; let created_at: Date; let author: ProfileRow?
    var model: PhotoComment {
        PhotoComment(id: id, photoID: photo_id, author: author?.model, authorID: author_id, body: body, createdAt: created_at)
    }
}

private struct CollectionRow: Codable {
    let id: UUID; let owner_id: UUID; let title: String; let place: String?; let shot_on: Date?
    var cover_photo_id: UUID?; let frame: FrameStyle; let visibility: String
    let like_count: Int?; let comment_count: Int?
    var photos: [PhotoRow]?
    var owner: ProfileRow?
    /// A name this build doesn't know reads as nil, the default look.
    let font: String?
    let board: Lenient<BatchBoard>?
    let description: String?
    let background: String?

    init(_ c: PhotoCollection) {
        id = c.id; owner_id = c.ownerID; title = c.title; place = c.place; shot_on = c.shotOn
        cover_photo_id = c.coverPhotoID; frame = c.frame; visibility = c.visibility.rawValue
        like_count = nil; comment_count = nil; photos = nil; owner = nil
        font = c.font?.rawValue; board = c.board.map { Lenient($0) }
        description = c.description; background = c.background?.raw
    }

    // Writes send only the pile's own columns; counts are kept by the database.
    enum CodingKeys: String, CodingKey {
        case id, owner_id, title, place, shot_on, cover_photo_id, frame, visibility, like_count, comment_count, photos, owner, font, board, description, background
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(owner_id, forKey: .owner_id); try c.encode(title, forKey: .title)
        try c.encode(place, forKey: .place); try c.encode(shot_on, forKey: .shot_on)
        try c.encode(cover_photo_id, forKey: .cover_photo_id); try c.encode(frame, forKey: .frame)
        try c.encode(visibility, forKey: .visibility)
        // Only once chosen. Choosing "Classic" sends it, so going back to the default is saved, and a
        // batch that never had either saves fine before the migration adding them has run.
        try c.encodeIfPresent(font, forKey: .font)
        try c.encodeIfPresent(board?.value, forKey: .board)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(background, forKey: .background)
    }

    var model: PhotoCollection {
        PhotoCollection(id: id, ownerID: owner_id, title: title, place: place, shotOn: shot_on,
                        photos: (photos ?? []).map(\.model).sorted { $0.sortIndex < $1.sortIndex },
                        coverPhotoID: cover_photo_id, frame: frame,
                        visibility: .init(rawValue: visibility) ?? .private,
                        likeCount: like_count ?? 0, commentCount: comment_count ?? 0,
                        owner: owner?.model,
                        font: font.flatMap(BatchFont.init(rawValue:)), board: board?.value,
                        description: description, background: background.flatMap(BatchBackground.init(raw:)))
    }
}

/// Only what other people need. Local file locations (the developed file, the RAW, the
/// original, the Photos asset) stay on the device in LocalLibrary.
private struct PhotoRow: Codable {
    let id: UUID; let collection_id: UUID
    let pixel_width: Int; let pixel_height: Int; let caption: String?; let captured_at: Date?
    let exif: Photo.Exif?; let sort_index: Int
    let edit: EditRecipe?; let share_path: String?
    /// null for the pile's owner; set when a friend added the photo to a group pile.
    let added_by: UUID?

    init(_ p: Photo) {
        id = p.id; collection_id = p.collectionID
        pixel_width = p.pixelWidth; pixel_height = p.pixelHeight; caption = p.caption
        captured_at = p.capturedAt; exif = p.exif; sort_index = p.sortIndex
        edit = p.edit; share_path = p.sharePath; added_by = p.addedBy
    }

    var model: Photo {
        Photo(id: id, collectionID: collection_id, imageURL: Photo.missingImage, rawURL: nil,
              pixelWidth: pixel_width, pixelHeight: pixel_height, caption: caption,
              capturedAt: captured_at, exif: exif, sortIndex: sort_index,
              edit: edit, sharePath: share_path, addedBy: added_by)
    }
}
