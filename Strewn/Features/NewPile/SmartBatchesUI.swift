import Photos
import SwiftUI

/// The "Suggested" row at the top of New batch: days and trips from the camera roll, each
/// shown as a small fanned pile of its own prints. Before access is granted it's one card that
/// asks; without access it disappears and the system picker below works as it always has.
/// Hold a card to see more of it, or to hide a suggestion you don't want.
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("SUGGESTED").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
                    if !suggestions.batches.isEmpty {
                        Text("· days and trips from your camera roll").font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if suggestions.isLoading { ProgressView().controlSize(.small) }
                }
                if suggestions.batches.isEmpty {
                    if suggestions.hasLoaded && !suggestions.isLoading {
                        Text(suggestions.access == .limited
                             ? "No days or trips among the photos Batches can see."
                             : "No new days or trips from the last year.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        loadingRow
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(suggestions.batches) { batch in
                                Button { onOpen(batch) } label: {
                                    SuggestionCard(batch: batch, place: suggestions.places[batch.id])
                                }
                                .buttonStyle(PressablePileStyle())
                                .contextMenu {
                                    Button { onOpen(batch) } label: { Label("Review photos", systemImage: "square.grid.2x2") }
                                    Button(role: .destructive) {
                                        withAnimation(.snappy) { suggestions.hide(batch) }
                                    } label: { Label("Hide this suggestion", systemImage: "eye.slash") }
                                } preview: {
                                    SuggestionPeek(batch: batch, place: suggestions.places[batch.id])
                                }
                                .onAppear { suggestions.nameIfNeeded(batch) }
                            }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
                if suggestions.access == .limited { limitedNote }
            }
        }
    }

    /// Three blank piles while the library is grouped, so the row doesn't jump in.
    private var loadingRow: some View {
        HStack(spacing: 18) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.card).frame(width: 112, height: 112)
                        .frame(width: SuggestionCard.width, height: SuggestionCard.pileHeight)
                    RoundedRectangle(cornerRadius: 3).fill(Color.card).frame(width: 96, height: 12)
                    RoundedRectangle(cornerRadius: 3).fill(Color.card).frame(width: 70, height: 10)
                }
            }
        }
        .padding(.top, 10)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
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

/// Sinks a pile a little while it's pressed, like pressing on a stack of prints.
private struct PressablePileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A print as it sits in a suggestion: a square white mat of a fixed size with the whole
/// photo centred inside it, so every print in a pile is the same shape whatever the photo.
private struct SuggestionPrint: View {
    let image: UIImage?
    var side: CGFloat

    var body: some View {
        ZStack {
            Color(white: 0.985)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.07)
            } else {
                Rectangle().fill(Color.black.opacity(0.05)).padding(side * 0.07)
            }
        }
        .frame(width: side, height: side)
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1.5)
    }
}

/// One suggestion: a tidy pile of three of its photos, its name, when it was, and a count.
struct SuggestionCard: View {
    let batch: SmartBatch
    let place: String?

    static let width: CGFloat = 150
    static let pileHeight: CGFloat = 132
    private static let printSide: CGFloat = 112

    @State private var images: [UIImage] = []

    /// Back left, back right, front: small, even tilts so the pile reads as a stack.
    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [(-5, -8, -3), (4, 8, -4), (0, 0, 3)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let spot = Self.fan[index]
                    SuggestionPrint(image: index < images.count ? images[index] : nil, side: Self.printSide)
                        .rotationEffect(.degrees(spot.angle))
                        .offset(x: spot.x, y: spot.y)
                }
            }
            .frame(width: Self.width, height: Self.pileHeight)
            .overlay(alignment: .topLeading) {
                if batch.isTrip {
                    Label("Trip", systemImage: "airplane")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.strewnAccent, in: Capsule())
                        .foregroundStyle(Color.onAccent)
                        .offset(x: 4, y: 0)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(batch.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: -8, y: -4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place ?? batch.dateLabel)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .lineLimit(1)
                Text(detail).metaStyle().lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(batch.isTrip ? "Trip, " : "")\(batch.suggestedTitle(place: place)), \(batch.count.counted("photo"))")
        .accessibilityHint("Opens the photos to pick from. Touch and hold for more.")
        .task(id: batch.id) {
            // Spread through the day: the middle says more about it than its first frame.
            let ids = batch.assetIDs
            let picks = [ids[ids.count / 4], ids[(ids.count * 3) / 4], ids[ids.count / 2]]
            var loaded: [UIImage] = []
            for asset in SmartBatchSuggestions.assets(withIDs: picks) {
                if let image = await LibraryThumbnails.image(for: asset, maxPixelSide: 360) { loaded.append(image) }
            }
            withAnimation(.easeOut(duration: 0.25)) { images = loaded }
        }
    }

    /// Under the name: the date when the name is a place, otherwise the weekday; trips say how
    /// many days they ran.
    private var detail: String {
        if batch.isTrip, batch.dayCount > 1 {
            return place == nil ? batch.dayCount.counted("day") : "\(batch.dateLabel) · \(batch.dayCount.counted("day"))"
        }
        return place == nil ? batch.start.formatted(.dateTime.weekday(.wide)) : batch.dateLabel
    }
}

/// What holding a suggestion shows: a contact sheet of its first photos with its name.
private struct SuggestionPeek: View {
    let batch: SmartBatch
    let place: String?
    @State private var images: [UIImage] = []

    private static let shown = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 4), count: 3), spacing: 4) {
                ForEach(0..<Self.shown, id: \.self) { index in
                    ZStack {
                        Rectangle().fill(.foreground.opacity(0.06))
                        if index < images.count {
                            Image(uiImage: images[index]).resizable().scaledToFill()
                        }
                    }
                    .frame(width: 104, height: 104)
                    .clipped()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.suggestedTitle(place: place)).font(.system(.headline, design: .serif, weight: .semibold))
                Text(batch.isTrip && batch.dayCount > 1
                     ? "\(batch.dayCount.counted("day")) · \(batch.count.counted("photo"))"
                     : batch.count.counted("photo"))
                    .metaStyle(.caption)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 344)
        .background(Color(uiColor: .systemBackground))
        .task {
            // Evenly through the batch, so a trip's peek covers the whole trip.
            let ids = batch.assetIDs
            let count = min(Self.shown, ids.count)
            let picks = (0..<count).map { ids[$0 * ids.count / count] }
            for asset in SmartBatchSuggestions.assets(withIDs: picks) {
                if let image = await LibraryThumbnails.image(for: asset, maxPixelSide: 240) { images.append(image) }
            }
        }
    }
}

/// The review screen: every photo in a suggestion at its own shape, grouped by day for trips.
/// Tap a photo to include or leave it out; touch and hold to see it big first. "Use these"
/// sends the picks back to New batch.
struct SmartBatchReviewView: View {
    let batch: SmartBatch
    let place: String?
    /// What's left of the 60-photo batch after picks from other places (Google Photos).
    var limit = 60
    /// The button that takes the picks: "Use these" in New batch, "Add to batch" for one that exists.
    var useTitle = "Use these"
    var onUse: ([PHAsset]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var days: [Day] = []
    @State private var selected: Set<String> = []
    @State private var hitLimit = 0

    struct Day: Identifiable {
        let id: DateComponents
        let date: Date
        let indices: [Int]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: batch.suggestedTitle(place: place), onCancel: { dismiss() })
            GeometryReader { geo in
                ScrollView {
                    // Rows are separate lazy children, so a long trip only loads what's on screen.
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: days.count > 1 ? [.sectionHeaders] : []) {
                        summary.padding(.bottom, 12)
                        ForEach(days) { day in
                            Section {
                                grid(day.indices, width: geo.size.width - 32)
                            } header: {
                                if days.count > 1 { dayHeader(day) }
                            }
                        }
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
        .sensoryFeedback(.selection, trigger: selected.count)
        .task {
            let loaded = SmartBatchSuggestions.assets(withIDs: batch.assetIDs)
            assets = loaded
            days = Self.days(of: loaded)
            selected = Set(Self.defaultPicks(loaded, limit: limit).map(\.localIdentifier))
        }
    }

    /// Everything when it fits; otherwise an even spread across the whole batch, so a long trip
    /// isn't just its first morning.
    static func defaultPicks(_ assets: [PHAsset], limit: Int) -> [PHAsset] {
        guard assets.count > limit, limit > 0 else { return assets }
        return (0..<limit).map { assets[$0 * assets.count / limit] }
    }

    private static func days(of assets: [PHAsset]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        var current: (key: DateComponents, date: Date, indices: [Int])?
        for (index, asset) in assets.enumerated() {
            let date = asset.creationDate ?? .distantPast
            let key = calendar.dateComponents([.year, .month, .day], from: date)
            if current?.key == key {
                current?.indices.append(index)
            } else {
                if let current { days.append(Day(id: current.key, date: current.date, indices: current.indices)) }
                current = (key, date, [index])
            }
        }
        if let current { days.append(Day(id: current.key, date: current.date, indices: current.indices)) }
        return days
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if batch.isTrip {
                    Label("Trip", systemImage: "airplane").font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.strewnAccent, in: Capsule())
                        .foregroundStyle(Color.onAccent)
                }
                Text(summaryLine).metaStyle(.caption)
            }
            if assets.count > limit {
                Text(limit < 60
                     ? "There's room for \(limit) more with your other picks, so \(limit) are picked from across the \(batch.isTrip ? "trip" : "day"). Tap to swap."
                     : "A batch holds up to \(limit) photos, so \(limit) are picked from across the \(batch.isTrip ? "trip" : "day"). Tap to swap.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button(selected.isEmpty ? "Select \(assets.count > limit ? "\(limit)" : "all")" : "Clear all") {
                    selected = selected.isEmpty ? Set(Self.defaultPicks(assets, limit: limit).map(\.localIdentifier)) : []
                }
                Spacer()
                Label("Hold a photo to see it big", systemImage: "hand.tap").labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.semibold))
        }
    }

    private var summaryLine: String {
        var parts = [batch.dateLabel]
        if batch.isTrip, batch.dayCount > 1 { parts.append(batch.dayCount.counted("day")) }
        parts.append(batch.count.counted("photo"))
        return parts.joined(separator: " · ")
    }

    private func dayHeader(_ day: Day) -> some View {
        let ids = day.indices.map { assets[$0].localIdentifier }
        let picked = ids.filter(selected.contains).count
        return HStack(alignment: .firstTextBaseline) {
            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(.subheadline, design: .serif, weight: .semibold))
            Text("\(picked) of \(ids.count)").metaStyle()
            Spacer()
            Button(picked == ids.count ? "Clear day" : "Add day") { toggleDay(ids, allPicked: picked == ids.count) }
                .font(.footnote.weight(.semibold))
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
        .padding(.horizontal, 4)
        .background(.bar.opacity(0.92))
    }

    private func toggleDay(_ ids: [String], allPicked: Bool) {
        withAnimation(.snappy(duration: 0.15)) {
            if allPicked {
                selected.subtract(ids)
            } else {
                let room = limit - selected.count
                let toAdd = ids.filter { !selected.contains($0) }
                selected.formUnion(toAdd.prefix(max(0, room)))
                if toAdd.count > room { hitLimit += 1 }
            }
        }
    }

    @ViewBuilder private func grid(_ indices: [Int], width: CGFloat) -> some View {
        let rows = JustifiedRows.rows(aspects: indices.map { CGFloat(assets[$0].pixelWidth) / CGFloat(max(assets[$0].pixelHeight, 1)) },
                                      width: max(width, 100), targetHeight: 118, spacing: 4)
        ForEach(rows.indices, id: \.self) { r in
                let row = rows[r]
                HStack(spacing: 4) {
                    ForEach(row.items, id: \.index) { item in
                        let asset = assets[indices[item.index]]
                        let isSelected = selected.contains(asset.localIdentifier)
                        ReviewThumbnail(asset: asset, isSelected: isSelected)
                            .frame(width: item.width, height: row.height)
                            .onTapGesture { toggle(asset) }
                            .contextMenu {
                                Button { toggle(asset) } label: {
                                    isSelected ? Label("Leave out", systemImage: "minus.circle") : Label("Include", systemImage: "checkmark.circle")
                                }
                            } preview: {
                                PhotoPeek(asset: asset, isSelected: isSelected)
                            }
                    }
                    Spacer(minLength: 0)
                }
        }
    }

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < limit {
            selected.insert(id)
        } else {
            hitLimit += 1
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selected.count) picked").font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("up to \(limit)").metaStyle()
            }
            Button {
                onUse(assets.filter { selected.contains($0.localIdentifier) })
                dismiss()
            } label: {
                Text(selected.isEmpty ? "Pick some photos" : useTitle)
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

/// One photo in the review grid, drawn whole at its own shape. Left-out photos fade back.
private struct ReviewThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // The slot already has the photo's shape, so filling it shows the whole photo with
            // no slivers of background when a thumbnail's size rounds a little differently.
            Rectangle().fill(.foreground.opacity(0.06))
                .overlay {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                }
                .clipped()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.onAccent : Color.white, isSelected ? Color.strewnAccent : Color.black.opacity(0.3))
                .shadow(color: .black.opacity(0.25), radius: 2)
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .saturation(isSelected ? 1 : 0.4)
        .opacity(isSelected ? 1 : 0.5)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.15), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Touch and hold to see it bigger.")
        .task(id: asset.localIdentifier) { image = await LibraryThumbnails.image(for: asset, maxPixelSide: 360) }
    }
}

/// What holding a photo shows: the whole photo, big and sharp, with when it was taken.
private struct PhotoPeek: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        let aspect = CGFloat(asset.pixelWidth) / CGFloat(max(asset.pixelHeight, 1))
        let width: CGFloat = aspect >= 1 ? 360 : max(220, min(360, 480 * aspect))
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.foreground.opacity(0.06))
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
            }
            .frame(width: width, height: width / max(aspect, 0.2))
            HStack {
                Text(asset.creationDate?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) ?? "")
                    .metaStyle(.caption)
                Spacer()
                if isSelected {
                    Label("Included", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.strewnAccent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: width)
        }
        .background(Color(uiColor: .systemBackground))
        .task { image = await LibraryThumbnails.image(for: asset, maxPixelSide: 1400) }
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
    /// its size and capture date read from the file, and its asset id kept. iCloud-only photos
    /// download a few at a time; `progress` gets (done, total). Photos that couldn't be copied
    /// are left out, so compare the count with `assets`.
    @MainActor
    static func photos(from assets: [PHAsset], collectionID: UUID,
                       progress: ((Int, Int) -> Void)? = nil) async -> [Photo] {
        let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var copied = [URL?](repeating: nil, count: assets.count)
        var done = 0
        progress?(0, assets.count)
        await withTaskGroup(of: (Int, URL?).self) { group in
            var next = 0
            func addNext() {
                guard next < assets.count, !Task.isCancelled else { return }
                let index = next, asset = assets[index]
                next += 1
                group.addTask { (index, await copyFile(of: asset, into: dir)) }
            }
            for _ in 0..<4 { addNext() }
            for await (index, url) in group {
                copied[index] = url
                done += 1
                progress?(done, assets.count)
                addNext()
            }
        }
        var photos: [Photo] = []
        for (asset, url) in zip(assets, copied) {
            guard let url else { continue }
            let info = metadata(of: url, fallbackAsset: asset)
            photos.append(Photo(id: UUID(), collectionID: collectionID, imageURL: url, rawURL: nil,
                                pixelWidth: info.width, pixelHeight: info.height, caption: nil,
                                capturedAt: info.capturedAt ?? asset.creationDate, exif: info.exif, sortIndex: photos.count,
                                photosAssetID: asset.localIdentifier))
        }
        return photos
    }

    /// The edited full-size photo when Photos has one, otherwise the original. iCloud photos
    /// download as needed.
    nonisolated private static func copyFile(of asset: PHAsset, into dir: URL) async -> URL? {
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
