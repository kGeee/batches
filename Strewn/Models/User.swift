import Foundation

struct User: Identifiable, Hashable, Codable {
    let id: UUID
    var handle: String
    var displayName: String
    var avatarURL: URL?
    var followerCount: Int
    var followingCount: Int

    /// Handles are lowercase letters, digits, dots and underscores, 3 to 24 long (matches the profiles table in supabase/migrations).
    static func isValidHandle(_ handle: String) -> Bool {
        handle.wholeMatch(of: #/[a-z0-9_.]{3,24}/#) != nil
    }
}
