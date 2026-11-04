import Foundation

/// Placeholder data for previews and the demo backend. Ids and image seeds are derived from
/// the titles with a fixed hash (Swift's hashValue changes every launch), so a relaunch shows
/// the same people and piles.
enum SampleData {
    static let me = person(1, "kevin", "kevin")
    static let maya = person(2, "maya.r", "Maya R")
    static let jules = person(3, "jules", "Jules")
    static let theo = person(4, "theo_shoots", "Theo")
    static let people = [me, maya, jules, theo]

    private static func person(_ n: Int, _ handle: String, _ name: String) -> User {
        User(id: UUID(uuidString: String(format: "6B1E0C1A-0000-4000-8000-%012X", n))!, handle: handle,
             displayName: name, avatarURL: nil, followerCount: 0, followingCount: 0)
    }

    /// FNV-1a, so sample ids don't change between launches.
    private static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    static func collection(_ title: String, owner: User = me, place: String, sizes: [(Int, Int)], frame: FrameStyle,
                           visibility: PhotoCollection.Visibility = .private, daysAgo: Int = 0) -> PhotoCollection {
        let h = stableHash(title)
        let id = UUID(uuidString: String(format: "6B1E0C1A-0001-4000-8000-%012llX", h & 0xFFFF_FFFF_FFFF))!
        let photos = sizes.enumerated().map { i, size in
            Photo(id: UUID(uuidString: String(format: "6B1E0C1A-0002-4000-%04X-%012llX", i, h & 0xFFFF_FFFF_FFFF))!,
                  collectionID: id,
                  // picsum refuses anything over 5000 px, so ask for half size; the shape is what matters.
                  imageURL: URL(string: "https://picsum.photos/seed/\(h % 100_000 + UInt64(i))/\(size.0 / 2)/\(size.1 / 2)")!,
                  rawURL: nil, pixelWidth: size.0, pixelHeight: size.1, caption: nil,
                  capturedAt: .now, exif: nil, sortIndex: i)
        }
        return PhotoCollection(id: id, ownerID: owner.id, title: title, place: place,
                               shotOn: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now),
                               photos: photos, coverPhotoID: photos.first?.id, frame: frame, visibility: visibility)
    }

    static let collections: [PhotoCollection] = [
        collection("Big Sur, one afternoon", place: "Highway 1",
                   sizes: [(3000, 2000), (2000, 3000), (6000, 2000), (2400, 3000), (3840, 2160)],
                   frame: FrameStyle(kind: .whiteBorder, borderWidth: 14), visibility: .followers, daysAgo: 17),
        collection("Joshua Tree overnight", place: "Joshua Tree",
                   sizes: [(3840, 2160), (2000, 3000), (3000, 2000), (6000, 2000)],
                   frame: FrameStyle(kind: .filmStrip, borderWidth: 10, wall: .dark), visibility: .people, daysAgo: 30),
        collection("Fog over the bay", place: "Marin Headlands",
                   sizes: [(6000, 2000), (3000, 2000), (2400, 3000)],
                   frame: FrameStyle(kind: .galleryMat, borderWidth: 14), daysAgo: 45)
    ]

    /// Friends' piles for the demo. Their visibility decides who can see them, exactly as the
    /// database rules do: Maya's followers piles show because you follow her, Theo's pile is
    /// shared with you directly, Jules has a public pile and a private one you never see.
    static let friendCollections: [PhotoCollection] = [
        collection("Tomales Bay kayak", owner: maya, place: "Inverness",
                   sizes: [(3000, 2000), (2000, 3000), (3000, 2000)],
                   frame: FrameStyle(kind: .polaroid, borderWidth: 12), visibility: .followers, daysAgo: 2),
        collection("Night market", owner: maya, place: "Oakland",
                   sizes: [(2000, 3000), (3000, 2000)],
                   frame: FrameStyle(kind: .thinBlack, borderWidth: 6, wall: .dark), visibility: .followers, daysAgo: 9),
        collection("Mono Lake sunrise", owner: theo, place: "Lee Vining",
                   sizes: [(6000, 2000), (3000, 2000), (2400, 3000)],
                   frame: FrameStyle(kind: .filmStrip, borderWidth: 10, wall: .dark), visibility: .people, daysAgo: 4),
        collection("Desert roll", owner: jules, place: "Anza-Borrego",
                   sizes: [(3000, 2000), (3000, 2000), (2000, 3000)],
                   frame: FrameStyle(kind: .whiteBorder, borderWidth: 18), visibility: .public, daysAgo: 6),
        collection("Contact sheets", owner: jules, place: "Home",
                   sizes: [(3000, 2000)],
                   frame: FrameStyle(), visibility: .private, daysAgo: 1)
    ]

    /// Who follows whom when the demo starts.
    static let follows: [(follower: UUID, followee: UUID)] = [
        (me.id, maya.id), (maya.id, me.id), (theo.id, me.id), (jules.id, maya.id)
    ]

    /// Direct shares when the demo starts: (pile title, person it is shared with).
    static let shares: [(title: String, with: UUID)] = [
        ("Mono Lake sunrise", me.id), ("Joshua Tree overnight", maya.id)
    ]

    /// Which of those shares also let the person add photos: Theo's roll is a group pile.
    static let groupShares: [(title: String, with: UUID)] = [("Mono Lake sunrise", me.id)]
}
