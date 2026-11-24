import SwiftUI
import UIKit

/// Makes Instagram and TikTok ready posts from a batch or one photo, then opens the share sheet
/// so you can pick Instagram, TikTok, Save to Photos or anything else. Photos stay full frame on a
/// blurred or plain background unless you choose Crop. Only photos you added can go in, since
/// these leave Batches as your post.
struct SocialShareSheet: View {
    let collection: PhotoCollection
    /// The photos you may post, in batch order.
    let photos: [Photo]
    /// Opened on one photo: post just that one, with no picker.
    var single: Photo? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var output = SocialOutput.images
    @State private var format = SocialFormat.portrait
    @State private var fill = SocialFill.blur
    @State private var chosen: [UUID] = []
    @State private var secondsPerPhoto = 2.5
    @State private var slowZoom = true
    @State private var preview: UIImage?
    @State private var working: Task<Void, Never>?
    @State private var progress: Double = 0
    @State private var failure: String?

    private var limit: Int { output == .video ? SocialLayout.videoLimit : SocialLayout.carouselLimit }
    private var picked: [Photo] {
        if let single { return [single] }
        return photos.filter { chosen.contains($0.id) }
    }
    private var background: CGColor { collection.backdrop.postColor }

    var body: some View {
        PaperSheet(title: single == nil ? "Post this batch" : "Post this photo", onCancel: cancel,
                   confirmTitle: "Share", confirmEnabled: !picked.isEmpty, confirmBusy: working != nil, onConfirm: share) {
            previewCard

            if single == nil && photos.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    PaperLabel("Make").padding(.horizontal, 4)
                    Picker("Make", selection: $output) {
                        ForEach(SocialOutput.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            PaperSection(title: "Size") {
                ForEach(Array(SocialFormat.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 { PaperDivider(inset: 52) }
                    PaperChoiceRow(title: option.title, detail: option.detail, symbol: symbol(option),
                                   selected: format == option) { withAnimation(.snappy) { format = option } }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                PaperLabel("Around the photo").padding(.horizontal, 4)
                Picker("Around the photo", selection: $fill) {
                    ForEach(SocialFill.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(fillNote).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if output == .video {
                PaperSection(title: "Video", footer: videoNote) {
                    PaperRow {
                        Picker("Each photo", selection: $secondsPerPhoto) {
                            Text("1.5 s").tag(1.5)
                            Text("2.5 s").tag(2.5)
                            Text("4 s").tag(4.0)
                        }
                        .pickerStyle(.segmented)
                    }
                    PaperDivider()
                    PaperRow { Toggle("Slow zoom", isOn: $slowZoom).tint(.strewnAccent) }
                }
            }

            if single == nil && photos.count > 1 { photoPicker }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            Label("Made on this phone, without location. Nothing is posted until you pick an app.", systemImage: "lock")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .onAppear {
            if chosen.isEmpty { chosen = photos.prefix(SocialLayout.carouselLimit).map(\.id) }
        }
        .onChange(of: output) { _, now in
            // A slideshow is for Reels and TikTok, which want full screen.
            if now == .video { format = .vertical }
            if chosen.count > limit { chosen = Array(chosen.prefix(limit)) }
        }
        .task(id: PreviewKey(photo: picked.first?.id, format: format, fill: fill)) { await renderPreview() }
        .onDisappear { working?.cancel() }
        .interactiveDismissDisabled(working != nil)
    }

    // MARK: Preview

    private var previewCard: some View {
        let size = format.size
        return ZStack {
            if let preview {
                Image(uiImage: preview).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.quaternary)
            }
            if working != nil {
                Rectangle().fill(.black.opacity(0.45))
                VStack(spacing: 8) {
                    ProgressView(value: progress).tint(.white).frame(width: 120)
                    Text(output == .video ? "Making the video" : "Making \(picked.count.counted("post"))")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .frame(maxHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .overlay(alignment: .topTrailing) {
            if single == nil, picked.count > 1 {
                Text(output == .video ? "1 of \(picked.count)" : "1 / \(picked.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: format)
        .accessibilityLabel("Preview of the first post, \(format.ratioLabel)")
    }

    private func renderPreview() async {
        guard let photo = picked.first else { preview = nil; return }
        let rendered = await SocialExport.post(photo, format: format, fill: fill, background: background)
        guard !Task.isCancelled else { return }
        preview = rendered.map { UIImage(cgImage: $0) }
    }

    // MARK: Picking photos

    private var photoPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PaperLabel("Photos").padding(.leading, 4)
                Spacer()
                Text("\(chosen.count) of up to \(min(limit, photos.count))").metaStyle()
                    .padding(.trailing, 4)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(photos) { photo in thumbnail(photo) }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: 84)
            Text(output == .video
                 ? "In batch order. Up to \(SocialLayout.videoLimit) photos in one video."
                 : "In batch order. Instagram carousels take up to \(SocialLayout.carouselLimit).")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func thumbnail(_ photo: Photo) -> some View {
        let on = chosen.contains(photo.id)
        let full = !on && chosen.count >= limit
        return Button {
            withAnimation(.snappy) {
                if on { chosen.removeAll { $0 == photo.id } } else if !full { chosen.append(photo.id) }
            }
        } label: {
            PhotoImage(photo: photo, tier: .s)
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(on ? 1 : (full ? 0.3 : 0.55))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? AnyShapeStyle(Color.strewnAccent) : AnyShapeStyle(.white))
                        .background(Circle().fill(.black.opacity(on ? 0 : 0.25)))
                        .padding(4)
                }
        }
        .buttonStyle(.plain)
        .disabled(full)
        .accessibilityLabel(on ? "Included" : "Not included")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Words

    private func symbol(_ option: SocialFormat) -> String {
        switch option {
        case .portrait: "rectangle.portrait"
        case .square: "square"
        case .vertical: "iphone"
        }
    }

    private var fillNote: String {
        switch fill {
        case .blur: "The whole photo, on a soft blur of itself."
        case .background: "The whole photo, on this batch's background."
        case .crop: "Fills the post. Edges that don't fit are cut off."
        }
    }

    private var videoNote: String {
        let seconds = Double(picked.count) * secondsPerPhoto
        let length = seconds < 60 ? "\(Int(seconds.rounded())) seconds" : String(format: "%.1f minutes", seconds / 60)
        return "About \(length), with no sound, so you can add music in Instagram or TikTok."
    }

    // MARK: Sharing

    private func cancel() {
        working?.cancel()
        dismiss()
    }

    private func share() {
        let photos = picked
        guard !photos.isEmpty else { return }
        failure = nil
        progress = 0
        let format = format, fill = fill, background = background, title = collection.title
        let options = SlideshowWriter.Options(secondsPerPhoto: secondsPerPhoto, slowZoom: slowZoom)
        let video = output == .video && photos.count > 1
        working = Task {
            defer { working = nil }
            do {
                let files: [URL]
                if video {
                    files = [try await SocialExport.video(photos, name: title, format: format, fill: fill, background: background,
                                                          options: options) { progress = $0 }]
                } else {
                    files = try await SocialExport.images(photos, name: title, format: format, fill: fill,
                                                          background: background) { progress = $0 }
                }
                guard !Task.isCancelled else { return }
                LinkShareSheet.present(items: files)
            } catch is CancellationError {
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "The post couldn't be made. Try again."
            }
        }
    }

    private struct PreviewKey: Hashable {
        let photo: UUID?
        let format: SocialFormat
        let fill: SocialFill
    }
}

extension SocialShareSheet {
    /// The photos in a batch you may post: in your own batch, the ones you added (not a friend's
    /// contributions); in someone else's group batch, only the ones you added there.
    static func postable(in collection: PhotoCollection, me: UUID?, isOwner: Bool) -> [Photo] {
        collection.photos.filter { canPost($0, isOwner: isOwner, me: me) }
    }

    static func canPost(_ photo: Photo, isOwner: Bool, me: UUID?) -> Bool {
        if photo.imageURL == Photo.missingImage && photo.sharePath == nil { return false }
        if photo.addedBy == nil { return isOwner }
        return photo.addedBy == me
    }
}
