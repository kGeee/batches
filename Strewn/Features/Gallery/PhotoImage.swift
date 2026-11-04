import ImageIO
import SwiftUI
import UIKit

/// The only way the app draws a photo. It always reserves the photo's true aspect ratio
/// (known from pixelWidth/pixelHeight before the bytes arrive) and always fits, never fills,
/// so no view can accidentally crop a frame the way square-grid feeds do.
///
/// Images are decoded at the size they're shown, not the file's full size (a 48 MP capture
/// on a pile print was most of the desk's scroll lag), and cached, so a photo flying from
/// the pile to the gallery never flashes empty.
struct PhotoImage: View {
    let photo: Photo
    /// For someone else's photo, which shared copy to load. nil picks the smallest copy that
    /// covers the size on screen. Your own photos load the local file.
    var tier: Photo.ShareTier? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var pixelSide = 0

    init(photo: Photo, tier: Photo.ShareTier? = nil) {
        self.photo = photo
        self.tier = tier
        let candidates = Photo.ShareTier.allCases.reversed().compactMap { photo.shareCopies[$0] } + [photo.imageURL]
        _image = State(initialValue: candidates.lazy.compactMap { PhotoImageLoader.shared.cachedImage(for: $0) }.first)
    }

    private var url: URL {
        let wanted = tier ?? Photo.ShareTier.allCases.first { $0.longEdge >= pixelSide } ?? .l
        return photo.shareCopies[wanted] ?? photo.imageURL
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high)
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(photo.aspectRatio, contentMode: .fit)
            .onGeometryChange(for: Int.self) { geo in
                PhotoImageLoader.bucket(for: max(geo.size.width, geo.size.height) * displayScale)
            } action: { pixelSide = $0 }
            .task(id: LoadKey(url: url, side: pixelSide)) {
                guard pixelSide > 0 else { return }
                if let current = image {
                    // Shrinking back into a pile: the copy on screen is already sharp enough.
                    if CGFloat(pixelSide) <= max(current.size.width, current.size.height) { return }
                    // Growing (a pile opening, a pinch): keep showing this copy until the size
                    // settles, so big decodes don't land in the middle of the animation. A
                    // further size change cancels this task and starts the wait again.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                if let loaded = await PhotoImageLoader.shared.image(for: url, maxPixelSide: pixelSide) {
                    if image == nil {
                        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                    } else {
                        image = loaded
                    }
                } else if image == nil {
                    failed = true
                }
            }
    }

    private struct LoadKey: Hashable {
        let url: URL
        let side: Int
    }
}

/// Decodes photos with ImageIO at a requested size and keeps them in memory. Sizes are
/// rounded up to a few buckets so a view animating between sizes doesn't decode every frame.
final class PhotoImageLoader: @unchecked Sendable {
    static let shared = PhotoImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var largest: [URL: Int] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    static func bucket(for pixels: CGFloat) -> Int {
        guard pixels > 0 else { return 0 }
        return [256, 512, 1024, 2048].first { CGFloat($0) >= pixels } ?? 4096
    }

    /// The biggest copy already decoded, for showing something immediately.
    func cachedImage(for url: URL) -> UIImage? {
        guard let side = lock.withLock({ largest[url] }) else { return nil }
        return cache.object(forKey: Self.key(url, side) as NSString)
    }

    func image(for url: URL, maxPixelSide side: Int) async -> UIImage? {
        let key = Self.key(url, side)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let task = lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
                await Self.decode(url, maxPixelSide: side)
            }
            inFlight[key] = task
            return task
        }
        let image = await task.value
        lock.withLock {
            inFlight[key] = nil
            if image != nil, side > largest[url] ?? 0 { largest[url] = side }
        }
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    private static func key(_ url: URL, _ side: Int) -> String { "\(side)|\(url.absoluteString)" }

    private static func decode(_ url: URL, maxPixelSide side: Int) async -> UIImage? {
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if url.scheme != "https" && url.scheme != "http" {
            return nil      // Photo.missingImage and anything else with nothing to fetch
        } else {
            // URLSession's shared cache keeps the bytes, so a bigger size later skips the network.
            guard let data = await download(url) else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,    // respects the file's orientation
            kCGImageSourceShouldCacheImmediately: true,          // decode here, not on the main thread at first draw
            kCGImageSourceThumbnailMaxPixelSize: side
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// One retry, since a pile asks for all its photos at once and the odd request drops.
    private static func download(_ url: URL) async -> Data? {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data
        }
        return nil
    }
}
