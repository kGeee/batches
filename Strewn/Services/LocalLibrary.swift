import Foundation

/// Where this device keeps each of your photos' files. The backend only knows a photo's shape,
/// caption, edit and shared copies; the developed file, the RAW, the untouched original and the
/// Photos asset live here, so RAW never leaves the phone and a pile loaded from the server still
/// edits from the real source on the device that shot it.
@MainActor
final class LocalLibrary {
    struct Files: Codable {
        var imageURL: URL
        var rawURL: URL?
        var originalURL: URL?
        var photosAssetID: String?

        /// The same files under this install's container. iOS can move an app's container
        /// when it's updated or reinstalled, so stored absolute paths go stale while the files
        /// themselves are still there.
        func rebased() -> Files {
            Files(imageURL: LocalLibrary.rebase(imageURL), rawURL: rawURL.map(LocalLibrary.rebase),
                  originalURL: originalURL.map(LocalLibrary.rebase), photosAssetID: photosAssetID)
        }
    }

    private var files: [UUID: Files]
    private let storeURL: URL

    init() {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appending(path: "local-library.json")
        let stored = (try? JSONDecoder().decode([UUID: Files].self, from: Data(contentsOf: storeURL))) ?? [:]
        files = stored.mapValues { $0.rebased() }
        if files.values.map(\.imageURL) != stored.values.map(\.imageURL) { save() }
    }

    /// A file URL from an earlier install, moved under the current container: everything after
    /// the container folder (Documents/…, Library/…) is kept. Other URLs pass through.
    nonisolated static func rebase(_ url: URL) -> URL {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { return url }
        let parts = url.pathComponents
        guard let start = parts.firstIndex(where: { $0 == "Documents" || $0 == "Library" }) else { return url }
        var moved = URL.homeDirectory
        for part in parts[start...] { moved.append(path: part) }
        return FileManager.default.fileExists(atPath: moved.path) ? moved : url
    }

    /// Remembers a photo's local files. Remote URLs are ignored.
    func remember(_ photo: Photo) {
        guard photo.imageURL.isFileURL || photo.rawURL != nil || photo.photosAssetID != nil else { return }
        files[photo.id] = Files(imageURL: photo.imageURL, rawURL: photo.rawURL,
                                originalURL: photo.originalURL, photosAssetID: photo.photosAssetID)
        save()
    }

    func forget(_ photoIDs: [UUID]) {
        photoIDs.forEach { files[$0] = nil }
        save()
    }

    /// Puts local files back on photos loaded from the server, when this device has them.
    func merge(_ piles: [PhotoCollection]) -> [PhotoCollection] {
        piles.map { pile in
            var pile = pile
            for i in pile.photos.indices {
                guard let local = files[pile.photos[i].id],
                      !local.imageURL.isFileURL || FileManager.default.fileExists(atPath: local.imageURL.path) else { continue }
                pile.photos[i].imageURL = local.imageURL
                pile.photos[i].rawURL = local.rawURL
                pile.photos[i].originalURL = local.originalURL
                pile.photos[i].photosAssetID = local.photosAssetID
            }
            return pile
        }
    }

    private func save() {
        try? JSONEncoder().encode(files).write(to: storeURL, options: .atomic)
    }
}
