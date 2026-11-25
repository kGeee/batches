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
    @State private var transition = SlideTransition.fade
    @State private var preview: UIImage?
    /// Small renders of every picked photo for the video preview, in order; nil while loading.
    @State private var previewSlides: [UIImage?] = []
    @State private var previewPaused = false
    @State private var previewCache: [String: UIImage] = [:]
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
                    PaperRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Between photos").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Between photos", selection: $transition) {
                                ForEach(SlideTransition.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
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
        .task(id: VideoPreviewKey(photos: output == .video ? picked.map(\.id) : [], format: format, fill: fill)) {
            await renderVideoPreview()
        }
        .onDisappear { working?.cancel() }
        .interactiveDismissDisabled(working != nil)
    }

    // MARK: Preview

    private var previewCard: some View {
        let size = format.size
        return ZStack {
            if output == .video, picked.count > 0, previewSlides.contains(where: { $0 != nil }) {
                SlideshowPreview(slides: previewSlides, options: videoOptions, paused: previewPaused || working != nil)
                    .contentShape(Rectangle())
                    .onTapGesture { previewPaused.toggle() }
            } else if let preview {
                Image(uiImage: preview).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.quaternary)
            }
            if output == .video, previewPaused, working == nil {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.5), in: Circle())
                    .accessibilityHidden(true)
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
            if single == nil, picked.count > 1, output != .video {
                Text("1 / \(picked.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: format)
        .accessibilityLabel(output == .video ? "Video preview, \(format.ratioLabel). Tap to pause." : "Preview of the first post, \(format.ratioLabel)")
    }

    private func renderPreview() async {
        guard let photo = picked.first else { preview = nil; return }
        let rendered = await SocialExport.post(photo, format: format, fill: fill, background: background)
        guard !Task.isCancelled else { return }
        preview = rendered.map { UIImage(cgImage: $0) }
    }

    /// Draws every picked photo small (a third of full size), a few at a time, so the preview can
    /// play the whole video before it's made. Slides already drawn for the same photo and look
    /// are kept when only the selection changes.
    private func renderVideoPreview() async {
        let photos = picked
        guard output == .video, !photos.isEmpty else { previewSlides = []; return }
        let format = format, fill = fill, background = background
        let key = "\(format.rawValue)-\(fill.rawValue)"
        var slides: [UIImage?] = photos.map { previewCache["\(key)-\($0.id)"] }
        previewSlides = slides
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            var next = 0
            func addNext() {
                while next < photos.count, slides[next] != nil { next += 1 }
                guard next < photos.count else { return }
                let index = next, photo = photos[index]
                next += 1
                group.addTask {
                    let image = await SocialExport.post(photo, format: format, fill: fill, background: background,
                                                        scale: Self.previewScale)
                    return (index, image.map { UIImage(cgImage: $0) })
                }
            }
            for _ in 0..<3 { addNext() }
            for await (index, image) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                slides[index] = image
                if let image { previewCache["\(key)-\(photos[index].id)"] = image }
                previewSlides = slides
                addNext()
            }
        }
    }

    private static let previewScale: CGFloat = 1.0 / 3

    private var videoOptions: SlideshowWriter.Options {
        SlideshowWriter.Options(secondsPerPhoto: secondsPerPhoto, slowZoom: slowZoom, transition: transition)
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
        let options = videoOptions
        // A video was asked for, so make one even if only one photo is left ticked.
        let video = output == .video
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

    private struct VideoPreviewKey: Hashable {
        let photos: [UUID]
        let format: SocialFormat
        let fill: SocialFill
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

/// Plays a slideshow in the sheet before it's made: the same frame timing, cross-fade and slow
/// zoom as SlideshowWriter, drawn from small renders of each post. Slides still loading are
/// skipped over by holding the last one that's ready.
struct SlideshowPreview: View {
    let slides: [UIImage?]
    let options: SlideshowWriter.Options
    var paused = false

    @State private var start = Date.now
    @State private var pausedAt: TimeInterval?

    var body: some View {
        TimelineView(.animation(paused: paused)) { context in
            let timing = SlideshowWriter.Timing(slides: slides.count, options: options)
            let elapsed = pausedAt ?? context.date.timeIntervalSince(start)
            let total = max(1, timing.totalFrames)
            let frame = Int(elapsed * Double(SlideshowWriter.fps)) % total
            let index = frame / timing.framesPerSlide
            let fade = timing.fadeIn(frame: frame, slides: slides.count)
            GeometryReader { proxy in
                let changing = fade > 0 && index + 1 < slides.count && slides[index + 1] != nil
                let pose = options.transition.pose(fade)
                ZStack {
                    Color.black
                    slide(index, frame: frame, timing: timing, extraScale: changing ? pose.outgoingScale : 0)
                        .offset(x: changing ? pose.outgoingShift * proxy.size.width : 0)
                    if changing {
                        slide(index + 1, frame: frame, timing: timing, extraScale: pose.incomingScale)
                            .offset(x: pose.incomingShift * proxy.size.width)
                            .opacity(pose.incomingOpacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .bottom) {
                    // How far through the video, like a player's scrubber.
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(frame + 1) / CGFloat(total), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(.black.opacity(0.25)))
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
                .overlay(alignment: .topTrailing) {
                    Text("\(time(Double(frame) / Double(SlideshowWriter.fps))) / \(time(Double(total) / Double(SlideshowWriter.fps)))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
        }
        .onChange(of: paused) { _, now in
            if now {
                pausedAt = Date.now.timeIntervalSince(start)
            } else if let at = pausedAt {
                start = Date.now.addingTimeInterval(-at)
                pausedAt = nil
            }
        }
        // Start over when the photos or timing change.
        .onChange(of: slides.count) { restart() }
        .onChange(of: options) { restart() }
    }

    private func restart() {
        start = .now
        if pausedAt != nil { pausedAt = 0 }
    }

    /// The slide at `index`, or the nearest earlier one that has loaded, zoomed like the writer.
    @ViewBuilder
    private func slide(_ index: Int, frame: Int, timing: SlideshowWriter.Timing, extraScale: CGFloat = 0) -> some View {
        let ready = (0...min(index, slides.count - 1)).reversed().first { slides[$0] != nil }
        if let ready, let image = slides[ready] {
            let grow = options.slowZoom ? SlideshowWriter.zoomAmount * timing.zoomProgress(slide: index, frame: frame) : 0
            Image(uiImage: image).resizable().interpolation(.medium)
                .scaleEffect(1 + grow + extraScale)
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
