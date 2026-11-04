import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the small HEIC copies other people see, from a photo's developed file on this phone.
/// Only pixels and the color profile go in: no GPS or other metadata, and never the RAW.
/// Photos keep their own shape at every size (long edge from Photo.ShareTier; panoramas get
/// 1.6 times so their short side stays usable), so the full-frame rule holds for viewers too.
///
/// The storage plan's full ladder (10-bit, from RAW plus recipe) belongs to EditRenderer;
/// this is the simple version that makes sharing work today.
enum ShareCopyMaker {
    enum Failure: Error { case unreadable, encode }

    static func make(from url: URL) throws -> [Photo.ShareTier: Data] {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isPanorama = min(w, h) > 0 && Double(max(w, h)) / Double(min(w, h)) > 2.2

        var copies: [Photo.ShareTier: Data] = [:]
        for tier in Photo.ShareTier.allCases {
            let edge = Int(Double(tier.longEdge) * (isPanorama ? 1.6 : 1))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // bake in orientation
                kCGImageSourceThumbnailMaxPixelSize: max(w, h) > 0 ? min(edge, max(w, h)) : edge,   // never upscale
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { throw Failure.encode }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: tier == .s ? 0.65 : 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
            copies[tier] = data as Data
        }
        return copies
    }
}
