import Foundation

/// A pile: an album, day trip or shoot. Named PhotoCollection to avoid clashing with
/// Swift's `Collection` protocol.
struct PhotoCollection: Identifiable, Hashable, Codable {
    let id: UUID
    var ownerID: UUID
    var title: String
    var place: String?
    var shotOn: Date?
    var photos: [Photo]
    var coverPhotoID: UUID?
    var frame: FrameStyle
    /// New piles start private. Sharing is always something the owner chooses.
    var visibility: Visibility = .private
    var likeCount: Int = 0
    var commentCount: Int = 0
    /// Filled in by the backend for piles that aren't yours, so the feed can say whose they are.
    var owner: User? = nil
    /// People this pile is shared with directly (visibility .people, or on top of .followers).
    var sharedWith: [User] = []
    /// Owner only: which of `sharedWith` may add their own photos (a group pile).
    var contributorIDs: Set<UUID> = []
    /// For someone else's pile: whether you may add photos to it.
    var canAdd = false
    /// Profiles of the people who added photos, so each one can say whose it is.
    var contributors: [User] = []

    enum Visibility: String, Codable, CaseIterable, Identifiable {
        case `private`, people, followers, `public`
        var id: Self { self }

        var title: String {
            switch self {
            case .private: "Only me"
            case .people: "Specific people"
            case .followers: "Followers"
            case .public: "Anyone on Batches"
            }
        }

        var detail: String {
            switch self {
            case .private: "Stays on your desk. Nothing is uploaded."
            case .people: "Only the people you pick can open it."
            case .followers: "Everyone who follows you, plus anyone you add."
            case .public: "Shows on your profile for anyone signed in."
            }
        }

        var symbol: String {
            switch self {
            case .private: "lock"
            case .people: "person.2"
            case .followers: "person.3"
            case .public: "globe"
            }
        }
    }

    var isShared: Bool { visibility != .private }

    /// The person who added `photo`, when that wasn't the owner.
    func adder(of photo: Photo) -> User? {
        photo.addedBy.flatMap { id in contributors.first { $0.id == id } }
    }

    /// The cover, falling back to the first photo when none is chosen yet.
    var cover: Photo? {
        photos.first { $0.id == coverPhotoID } ?? photos.first
    }

    /// Up to `limit` photos for the desk pile, bottom first, with the cover on top.
    func pileStack(limit: Int = 5) -> [Photo] {
        guard let cover else { return [] }
        let others = photos.filter { $0.id != cover.id }.prefix(limit - 1)
        return Array(others) + [cover]
    }
}
