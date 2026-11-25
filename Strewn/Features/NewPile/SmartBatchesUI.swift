import Photos
import SwiftUI

/// The "Suggested" row at the top of New batch: days and trips from the camera roll, each
/// shown as a small pile. Before access is granted it's one card that asks; without access it
/// disappears and the system picker below works as it always has.
struct SuggestedBatchesRow: View {
    @Environment(AppModel.self) private var model
    var suggestions: SmartBatchSuggestions
    var frame: FrameStyle
    var onOpen: (SmartBatch) -> Void

    var body: some View {
        switch suggestions.access {
        case .notAsked: askCard
        case .denied: EmptyView()
        case .full, .limited:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SUGGESTED").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
                    Spacer()
                    if suggestions.isLoading { ProgressView().controlSize(.small) }
                }
                if suggestions.batches.isEmpty {
                    if suggestions.hasLoaded && !suggestions.isLoading {
                        Text(suggestions.access == .limited
                             ? "No days or trips among the photos Batches can see."
                             : "No new days or trips from the last year.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(suggestions.batches) { batch in
                                Button { onOpen(batch) } label: {
                                    SuggestionCard(batch: batch, place: suggestions.places[batch.id], frame: frame)
                                }
                                .buttonStyle(.plain)
                                .task { await suggestions.nameIfNeeded(batch) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
                if suggestions.access == .limited { limitedNote }
            }
        }
    }

    private var askCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack").font(.title2).foregroundStyle(Color.strewnAccent)
            VStack(alignment: .leading, spacing: 8) {
                Text("See your days and trips as batches").font(.subheadline.weight(.semibold))
                Text("Batches looks at when and where your photos were taken, on your phone. Nothing is uploaded.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on") {
                    Task { await suggestions.requestAccess(excluding: model.batchedAssetIDs) }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.foreground.opacity(0.08), lineWidth: 1))
    }

    private var limitedNote: some View {
        HStack(spacing: 14) {
            Text("Batches can see only some of your photos.").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Choose more") { suggestions.chooseMorePhotos(excluding: model.batchedAssetIDs) }
            Button("Allow all") { suggestions.openSettings() }
        }
        .font(.footnote.weight(.semibold))
    }
}

/// One suggestion: a small pile of its first prints, its name and how many photos it has.
struct SuggestionCard: View {
    let batch: SmartBatch
    let place: String?
    let frame: FrameStyle

    @State private var images: [UIImage] = []

    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [(-4, -10, 4), (6, 12, -4), (-1, 0, 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if images.isEmpty {
                    RoundedRectangle(cornerRadius: 3).fill(Color.card).frame(width: 96, height: 72)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    let spot = Self.fan[index % Self.fan.count]
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size, contentMode: .fit)   // full frame, never cropped
                        .frame(maxWidth: 96, maxHeight: 84)
                        .photoFrame(frame)
                        .rotationEffect(.degrees(spot.angle))
                        .offset(x: spot.x, y: spot.y)
                }
            }
            .frame(width: 150, height: 120)
            VStack(alignment: .leading, spacing: 2) {
                Text(place ?? batch.dateLabel)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .lineLimit(1)
                Text(place == nil ? batch.count.counted("photo") : "\(batch.dateLabel) · \(batch.count.counted("photo"))")
                    .metaStyle()
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(batch.suggestedTitle(place: place)), \(batch.count.counted("photo"))")
        .task(id: batch.id) {
            // The middle of a day says more about it than its first frame.
            let ids = batch.assetIDs
            let picks = [ids[ids.count / 3], ids[(ids.count * 2) / 3], ids[ids.count / 2]]
            var loaded: [UIImage] = []
            for asset in SmartBatchSuggestions.assets(withIDs: picks) {
                if let image = await LibraryThumbnails.image(for: asset, maxPixelSide: 240) { loaded.append(image) }
            }
            images = loaded
        }
    }
}

/// The review grid: every photo in a suggestion, already picked, at its own shape. Tap a photo
/// to leave it out; "Use these" sends the picks back to New batch.
struct SmartBatchReviewView: View {
    let batch: SmartBatch
    let place: String?
    var onUse: ([PHAsset]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var hitLimit = 0

    static let limit = 60

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: batch.suggestedTitle(place: place), onCancel: { dismiss() })
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(batch.dateLabel) · \(batch.count.counted("photo"))").metaStyle(.caption)
                            Spacer()
                            Button(selected.isEmpty ? "Select all" : "Clear") {
                                selected = selected.isEmpty ? Set(assets.prefix(Self.limit).map(\.localIdentifier)) : []
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        if batch.count > Self.limit {
                            Text("A batch holds up to \(Self.limit) photos, so the first \(Self.limit) are picked. Tap to swap.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        grid(width: geo.size.width - 32)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .sensoryFeedback(.warning, trigger: hitLimit)
        .task {
            assets = SmartBatchSuggestions.assets(withIDs: batch.assetIDs)
            selected = Set(assets.prefix(Self.limit).map(\.localIdentifier))
        }
    }

    @ViewBuilder private func grid(width: CGFloat) -> some View {
        let rows = JustifiedRows.rows(aspects: assets.map { CGFloat($0.pixelWidth) / CGFloat(max($0.pixelHeight, 1)) },
                                      width: max(width, 100), targetHeight: 118, spacing: 4)
        LazyVStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                let row = rows[r]
                HStack(spacing: 4) {
                    ForEach(row.items, id: \.index) { item in
                        let asset = assets[item.index]
                        ReviewThumbnail(asset: asset, isSelected: selected.contains(asset.localIdentifier))
                            .frame(width: item.width, height: row.height)
                            .onTapGesture { toggle(asset) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < Self.limit {
            selected.insert(id)
        } else {
            hitLimit += 1
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("\(selected.count) of \(Self.limit)").metaStyle(.footnote)
            Button {
                onUse(assets.filter { selected.contains($0.localIdentifier) })
                dismiss()
            } label: {
                Text(selected.isEmpty ? "Pick some photos" : "Use these")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(selected.isEmpty ? Color.secondary : Color.onAccent)
            .controlSize(.large)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One photo in the review grid, drawn whole at its own shape, dimmed when left out.
private struct ReviewThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.foreground.opacity(0.06))
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.onAccent : Color.white, isSelected ? Color.strewnAccent : Color.black.opacity(0.25))
                .padding(5)
        }
        .opacity(isSelected ? 1 : 0.45)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.15), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: asset.localIdentifier) { image = await LibraryThumbnails.image(for: asset, maxPixelSide: 360) }
    }
}

/// Rows of photos at their own shapes, each row scaled to fill the width, like a contact
/// sheet of mixed prints. Nothing is cropped; a short last row keeps the target height.
enum JustifiedRows {
    struct Item: Hashable {
        let index: Int
        let width: CGFloat
    }

    struct Row: Hashable {
        var items: [Item]
        var height: CGFloat
    }

    static func rows(aspects: [CGFloat], width: CGFloat, targetHeight: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var pending: [(index: Int, aspect: CGFloat)] = []

        func flush(fill: Bool) {
            guard !pending.isEmpty else { return }
            let gaps = spacing * CGFloat(pending.count - 1)
            let aspectSum = pending.map(\.aspect).reduce(0, +)
            let height = fill ? (width - gaps) / aspectSum : min(targetHeight, (width - gaps) / aspectSum)
            rows.append(Row(items: pending.map { Item(index: $0.index, width: $0.aspect * height) }, height: height))
            pending = []
        }

        for (index, raw) in aspects.enumerated() {
            let aspect = min(max(raw, 0.25), 4)   // keep panoramas and slivers usable
            pending.append((index, aspect))
            let gaps = spacing * CGFloat(pending.count - 1)
            if pending.map(\.aspect).reduce(0, +) * targetHeight + gaps >= width { flush(fill: true) }
        }
        flush(fill: false)
        return rows
    }
}

extension PhotoImport {
    /// Copies library photos picked from a suggestion into the app, the same way the system
    /// picker's picks are copied: the current version of each photo (with any Photos edit),
    /// its size and capture date read from the file, and its asset id kept.
    @MainActor
    static func photos(from assets: [PHAsset], collectionID: UUID) async -> [Photo] {
        let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var photos: [Photo] = []
        for (index, asset) in assets.enumerated() {
            guard let url = await copyFile(of: asset, into: dir) else { continue }
            let info = metadata(of: url, fallbackAsset: asset)
            photos.append(Photo(id: UUID(), collectionID: collectionID, imageURL: url, rawURL: nil,
                                pixelWidth: info.width, pixelHeight: info.height, caption: nil,
                                capturedAt: info.capturedAt ?? asset.creationDate, exif: info.exif, sortIndex: index,
                                photosAssetID: asset.localIdentifier))
        }
        return photos
    }

    /// The edited full-size photo when Photos has one, otherwise the original. iCloud photos
    /// download as needed.
    private static func copyFile(of asset: PHAsset, into dir: URL) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else { return nil }
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let url = dir.appending(path: "\(UUID().uuidString).\(ext.isEmpty ? "heic" : ext)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil ? url : nil)
            }
        }
    }
}
