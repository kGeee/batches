import Foundation
import CoreGraphics

/// One photo in a pile. Pixel size is stored so every view can lay the photo out at its
/// true aspect ratio before the image loads. Nothing in the app crops a photo.
struct Photo: Identifiable, Hashable, Codable {
    let id: UUID
    var collectionID: UUID
    /// Developed image (HEIF/JPEG) in storage.
    var imageURL: URL
    /// Optional RAW original (DNG), kept so the look can be changed later.
    var rawURL: URL?
    var pixelWidth: Int
    var pixelHeight: Int
    var caption: String?
    var capturedAt: Date?
    var exif: Exif?
    /// Position in the pile; lower numbers sit lower in the stack.
    var sortIndex: Int
    /// Untouched source for imported photos, kept once the photo has been edited.
    var originalURL: URL? = nil
    /// Current non-destructive edit, applied to rawURL ?? originalURL ?? imageURL.
    var edit: EditRecipe? = nil
    /// PHAsset local identifier when the photo also lives in the Photos library.
    var photosAssetID: String? = nil
    /// Where this photo's shared copies live in cloud storage ("{owner}/{photo}/{rev}"), or nil
    /// while nothing has been shared. Only developed HEIC copies are ever uploaded, never the RAW.
    var sharePath: String? = nil
    /// Signed links to the shared copies by size, filled in when a pile is loaded from the backend.
    var shareCopies: [ShareTier: URL] = [:]
    /// Who added this photo, in a group pile, when it wasn't the pile's owner. nil means the owner.
    var addedBy: UUID? = nil

    /// Stand-in for imageURL when a photo has no local file and no shared copy yet.
    static let missingImage = URL(string: "strewn:missing")!

    /// Shared copy sizes, long edge in pixels. A subset of the ladder in docs/storage-plan.md.
    enum ShareTier: String, Codable, CaseIterable {
        case s, m, l
        var longEdge: Int {
            switch self { case .s: 320; case .m: 800; case .l: 1800 }
        }
    }

    /// What the editor develops from: the DNG when there is one, otherwise the original file.
    var editSourceURL: URL { rawURL ?? originalURL ?? imageURL }

    var aspectRatio: CGFloat {
        guard pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    var orientation: Orientation {
        switch aspectRatio {
        case ..<0.95: return .portrait
        case 0.95...1.05: return .square
        case 1.05..<2.2: return .landscape
        default: return .panorama
        }
    }

    enum Orientation: String, Codable { case portrait, square, landscape, panorama }

    struct Exif: Hashable, Codable {
        var aperture: Double?
        var shutter: String?
        var iso: Int?
        var focalLength: Int?
        var lookID: String?
        var captureFormat: String?   // "bayerRAW", "proRAW", "heif"
    }
}
