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
    @State private var fit = Fit(side: 0, tier: .s)

    init(photo: Photo, tier: Photo.ShareTier? = nil) {
        self.photo = photo
        self.tier = tier
        let candidates = Photo.ShareTier.allCases.reversed().map { photo.source(for: $0) }
        _image = State(initialValue: candidates.lazy.compactMap { PhotoImageLoader.shared.cachedImage(for: $0) }.first)
    }

    private var wanted: Photo.ShareTier { tier ?? fit.tier }

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
            .onGeometryChange(for: Fit.self) { geo in
                let pixels = max(geo.size.width, geo.size.height) * displayScale
                return Fit(side: PhotoImageLoader.bucket(for: pixels), tier: .fitting(pixels: pixels))
            } action: { fit = $0 }
            .task(id: LoadKey(source: photo.source(for: wanted), side: fit.side)) { await load() }
    }

    private func load() async {
        let side = fit.side
        guard side > 0 else { return }
        let source = photo.source(for: wanted)
        if let current = image {
            // Shrinking back into a pile: the copy on screen is already sharp enough.
            if CGFloat(side) <= max(current.size.width, current.size.height) { return }
            // Growing (a pile opening, a pinch): keep showing this copy until the size
            // settles, so big decodes don't land in the middle of the animation. A
            // further size change cancels this task and starts the wait again.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }

        // The largest copy takes a moment to arrive, so show the tiny one while it does.
        var preview: Task<Void, Never>?
        if image == nil, wanted == .l, case .shared = source {
            let small = photo.source(for: .s)
            preview = Task {
                guard let loaded = await PhotoImageLoader.shared.image(for: small, maxPixelSide: 512),
                      !Task.isCancelled, image == nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
        defer { preview?.cancel() }

        // A dropped connection shouldn't leave a blank photo until the app is reopened.
        for wait in [0, 2, 6] {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            if let loaded = await PhotoImageLoader.shared.image(for: source, maxPixelSide: side) {
                guard !Task.isCancelled else { return }
                failed = false
                if image == nil {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                } else {
                    image = loaded
                }
                return
            }
        }
        if image == nil { failed = true }
    }

    private struct Fit: Equatable {
        let side: Int
        let tier: Photo.ShareTier
    }

    private struct LoadKey: Hashable {
        let source: PhotoSource
        let side: Int
    }
}

/// Where a photo's bytes come from. A shared copy is named by its storage path rather than its
/// signed link, because the link changes and the file at that path never does.
enum PhotoSource: Hashable, Sendable {
    case url(URL)
    case shared(path: String)

    fileprivate var key: String {
        switch self {
        case .url(let url): url.absoluteString
        case .shared(let path): path
        }
    }
}

extension Photo {
    /// A file on this phone always wins, so your own photos never use the network.
    func source(for tier: ShareTier) -> PhotoSource {
        if !imageURL.isFileURL, imageURL.scheme != "https", imageURL.scheme != "http", let sharePath {
            return .shared(path: "\(sharePath)/\(tier.rawValue).heic")
        }
        return .url(imageURL)
    }
}

/// Decodes photos with ImageIO at a requested size and keeps them in memory. Sizes are
/// rounded up to a few buckets so a view animating between sizes doesn't decode every frame.
final class PhotoImageLoader: @unchecked Sendable {
    static let shared = PhotoImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var largest: [String: Int] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// SharedPhotoDisk keeps shared copies, so a second cache in URLSession would only waste space.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    static func bucket(for pixels: CGFloat) -> Int {
        guard pixels > 0 else { return 0 }
        return [256, 512, 1024, 2048].first { CGFloat($0) >= pixels } ?? 4096
    }

    /// The biggest copy already decoded, for showing something immediately.
    func cachedImage(for source: PhotoSource) -> UIImage? {
        guard let side = lock.withLock({ largest[source.key] }) else { return nil }
        return cache.object(forKey: Self.key(source, side) as NSString)
    }

    func image(for source: PhotoSource, maxPixelSide side: Int) async -> UIImage? {
        let key = Self.key(source, side)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let task = lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
                await Self.decode(source, maxPixelSide: side)
            }
            inFlight[key] = task
            return task
        }
        let image = await task.value
        lock.withLock {
            inFlight[key] = nil
            if image != nil, side > largest[source.key] ?? 0 { largest[source.key] = side }
        }
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// For signing out: nothing of the last account's stays in memory or on disk.
    func forgetEverything() async {
        cache.removeAllObjects()
        lock.withLock { largest = [:] }
        SharedPhotoDisk.shared.clear()
        await PhotoLinks.shared.clear()
    }

    private static func key(_ source: PhotoSource, _ side: Int) -> String { "\(side)|\(source.key)" }

    private static func decode(_ source: PhotoSource, maxPixelSide side: Int) async -> UIImage? {
        let image: CGImageSource?
        switch source {
        case .shared(let path):
            guard let data = await sharedCopy(path) else { return nil }
            image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .url(let url) where url.isFileURL:
            image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .url(let url):
            guard url.scheme == "https" || url.scheme == "http" else { return nil }     // Photo.missingImage
            guard let data = await download(url) else { return nil }
            image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,    // respects the file's orientation
            kCGImageSourceShouldCacheImmediately: true,          // decode here, not on the main thread at first draw
            kCGImageSourceThumbnailMaxPixelSize: side
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// From disk if it's been downloaded before, otherwise through a signed link.
    private static func sharedCopy(_ path: String) async -> Data? {
        if let saved = SharedPhotoDisk.shared.data(for: path) { return saved }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let url = await PhotoLinks.shared.url(for: path) else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  let status = (response as? HTTPURLResponse)?.statusCode else { continue }
            if (200..<300).contains(status) {
                SharedPhotoDisk.shared.store(data, for: path)
                return data
            }
            // Expired or refused: the retry asks for a new link.
            await PhotoLinks.shared.invalidate(path)
        }
        return nil
    }

    /// One retry, since a pile asks for all its photos at once and the odd request drops.
    private static func download(_ url: URL) async -> Data? {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let (data, response) = try? await session.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data
        }
        return nil
    }
}
