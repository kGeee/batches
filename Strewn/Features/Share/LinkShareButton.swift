import LinkPresentation
import SwiftUI
import UIKit

/// Shares a batches.space link with its preview attached: the batch's title and a photo from
/// this phone. Messages shows that card to the person it's sent to without fetching anything,
/// so a private batch gets a real preview while the web page behind the link stays generic.
/// SwiftUI's ShareLink can't hand Messages this metadata, so this presents the share sheet itself.
struct LinkShareButton<Label: View>: View {
    let url: URL
    let title: String
    /// The photo shown in the preview: the one being shared, or the batch's cover.
    var photo: Photo?
    @ViewBuilder var label: () -> Label

    @State private var preparing = false

    var body: some View {
        Button {
            Task { await share() }
        } label: {
            label()
        }
        .disabled(preparing)
    }

    @MainActor
    private func share() async {
        preparing = true
        defer { preparing = false }
        var image: UIImage?
        if let photo {
            image = await Self.previewImage(photo)
        }
        LinkShareSheet.present(LinkShareItem(url: url, title: title, image: image))
    }

    /// A copy already decoded in memory if there is one; otherwise one from disk or the network,
    /// but never holding up the share sheet for more than a second. Without it the link is sent
    /// with just its title.
    private static func previewImage(_ photo: Photo) async -> UIImage? {
        for tier in Photo.ShareTier.allCases.reversed() {
            if let cached = PhotoImageLoader.shared.cachedImage(for: photo.source(for: tier)) { return cached }
        }
        // Not a task group: that would wait for the download to finish even after the second
        // is up. Whichever answers first wins and the other is ignored.
        return await withCheckedContinuation { continuation in
            let answer = AnswerOnce(continuation)
            Task { answer.give(await PhotoImageLoader.shared.image(for: photo.source(for: .m), maxPixelSide: 1024)) }
            Task { try? await Task.sleep(for: .seconds(1)); answer.give(nil) }
        }
    }
}

/// Resumes a continuation with the first answer it's given and ignores the rest.
private final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func give(_ image: UIImage?) {
        let waiting = lock.withLock { () -> CheckedContinuation<UIImage?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: image)
    }
}

/// The link plus the preview Messages and other apps show for it.
final class LinkShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let image: UIImage?

    init(url: URL, title: String, image: UIImage?) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        "\(title), on Batches"
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let image { metadata.imageProvider = NSItemProvider(object: image) }
        return metadata
    }
}

enum LinkShareSheet {
    /// Presents over whatever is on top, so it works from sheets and the photo viewer too.
    @MainActor
    static func present(_ item: LinkShareItem) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.compactMap(\.keyWindow).first?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(UIActivityViewController(activityItems: [item], applicationActivities: nil), animated: true)
    }
}
