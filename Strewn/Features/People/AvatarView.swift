import SwiftUI

/// A person's photo, or their initial on a color picked from their id so it stays the same everywhere.
struct AvatarView: View {
    let user: User?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { initial }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.paper, lineWidth: max(1.5, size / 20)))
        .accessibilityHidden(true)
    }

    /// Seven hues far enough apart to tell people apart at a glance.
    private static let hues: [Double] = [0.02, 0.08, 0.14, 0.33, 0.48, 0.60, 0.75]

    private var initial: some View {
        // From the whole id, not its first byte, which ids made the same way all share.
        let hue = user.map { u in
            // FNV-1a plus a final mix, so ids that differ only in their last byte (as the
            // sample people do) still land on far-apart hues.
            var h = withUnsafeBytes(of: u.id.uuid) { $0.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } }
            h ^= h >> 16; h &*= 0x85eb_ca6b; h ^= h >> 13; h &*= 0xc2b2_ae35; h ^= h >> 16
            return Self.hues[Int(h % UInt32(Self.hues.count))]
        } ?? 0.08
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.62),
                                       Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.85)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Text(user?.displayName.prefix(1).uppercased() ?? "").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
    }
}

/// Follow / Following, used on profiles and in search results.
/// Follow is one tap; unfollowing asks first, since it also hides their followers-only piles.
struct FollowButton: View {
    let user: User
    @Environment(AppModel.self) private var model
    @State private var confirmUnfollow = false

    var body: some View {
        let following = model.isFollowing(user)
        Button {
            if following { confirmUnfollow = true } else { Task { await model.toggleFollow(user) } }
        } label: {
            Text(following ? "Following" : "Follow").font(.subheadline.weight(.semibold)).frame(minWidth: 76)
        }
        .buttonStyle(.borderedProminent)
        .tint(following ? Color.secondary.opacity(0.25) : Color.strewnAccent)
        .foregroundStyle(following ? Color.primary : Color.onAccent)
        .sensoryFeedback(.selection, trigger: following)
        .confirmationDialog("Unfollow @\(user.handle)?", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { Task { await model.toggleFollow(user) } }
        } message: {
            Text("Their followers-only batches will leave your feed.")
        }
    }
}
