import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Start a pile from the Photos library: from a suggested day or trip, or with the system
/// picker. The chosen photos sit on the linen as a loose stack in the frame you pick, so you
/// see the pile before you make it.
struct NewPileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: [PhotosPickerItem] = []
    /// Photos taken from a suggested batch. Picking with the system picker replaces them.
    @State private var suggestedPicked: [PHAsset] = []
    @State private var suggestions = SmartBatchSuggestions()
    @State private var reviewing: SmartBatch?
    /// Filled in from a suggestion's place name, and editable.
    @State private var place = ""
    /// The name a suggestion filled in, so a later pick only replaces a name you didn't type.
    @State private var suggestedTitle: String?
    /// Picks already downloaded from Google Photos, ready to go with the library picks.
    @State private var googlePicked: [Photo] = []
    @State private var google = GooglePhotosPicking()
    @State private var previews: [UIImage] = []
    @State private var title = ""
    @State private var frame = FrameStyle()
    @State private var isImporting = false
    @FocusState private var naming: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: "New batch", onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    SuggestedBatchesRow(suggestions: suggestions, frame: frame) { reviewing = $0 }
                    VStack(spacing: 12) {
                        picker
                        if GooglePhotos.isConfigured { googleButton }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Name")
                        TextField("Big Sur, one afternoon", text: $title)
                            .font(.system(.title2, design: .serif, weight: .semibold))
                            .focused($naming)
                            .submitLabel(.done)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(naming ? 0.5 : 0.18)).frame(height: 1) }
                    }
                    if !suggestedPicked.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Place")
                            TextField("Where it was", text: $place)
                                .font(.system(.body, design: .serif))
                                .submitLabel(.done)
                                .padding(.vertical, 6)
                                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.18)).frame(height: 1) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        label("Frame")
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(FrameStyle.Kind.allCases) { kind in swatch(kind) }
                            }
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { createButton }
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .task(id: PreviewKey(library: selection, suggested: suggestedPicked.map(\.localIdentifier), google: googlePicked.map(\.id))) {
            await loadPreviews()
        }
        .task { await suggestions.load(excluding: model.batchedAssetIDs) }
        .onChange(of: selection) { _, picks in
            // The system picker takes over from a suggestion.
            if !picks.isEmpty, !suggestedPicked.isEmpty { useSuggestion([], from: nil) }
        }
        .sheet(item: $reviewing) { batch in
            SmartBatchReviewView(batch: batch, place: suggestions.places[batch.id]) { assets in
                useSuggestion(assets, from: batch)
            }
        }
        .googlePhotosAlert(google)
        .animation(.snappy, value: google.stage)
    }

    private struct PreviewKey: Equatable {
        let library: [PhotosPickerItem]
        let suggested: [String]
        let google: [UUID]
    }

    private var pickedCount: Int { selection.count + suggestedPicked.count + googlePicked.count }

    /// Puts a suggestion's photos on the stack in place of system picks, and fills in its name
    /// and place unless you've typed your own name.
    private func useSuggestion(_ assets: [PHAsset], from batch: SmartBatch?) {
        suggestedPicked = assets
        if !assets.isEmpty { selection = [] }
        let name = batch.flatMap { suggestions.places[$0.id] }
        let newTitle = batch?.suggestedTitle(place: name)
        if title.isEmpty || title == suggestedTitle { title = newTitle ?? "" }
        suggestedTitle = newTitle
        place = name ?? ""
    }

    /// Adds picks from Google Photos to the stack; the system picker stays the big target above.
    @ViewBuilder private var googleButton: some View {
        if google.isRunning {
            GooglePhotosStatus(picking: google)
        } else {
            Button {
                Task {
                    let photos = await google.run(collectionID: UUID(), maxCount: max(1, 60 - selection.count - suggestedPicked.count))
                    if !photos.isEmpty { googlePicked = photos }
                }
            } label: {
                HStack(spacing: 8) {
                    GooglePhotosMark(size: 17)
                    Text(googlePicked.isEmpty ? "From Google Photos" : "\(googlePicked.count) from Google Photos · change")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Color.card, in: Capsule())
                .overlay(Capsule().strokeBorder(.foreground.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
        }
    }

    /// The stack of chosen prints, which is also the button that opens the picker.
    private var picker: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: 60, matching: .images,
                     preferredItemEncoding: .current, photoLibrary: .shared()) {
            ZStack {
                if previews.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30))
                        Text("Choose photos").font(.headline)
                        Text("Up to 60 from your library").metaStyle()
                    }
                    .foregroundStyle(Color.strewnAccent)
                    .frame(width: 220, height: 170)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.strewnAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                } else {
                    ForEach(Array(previews.enumerated().reversed()), id: \.offset) { index, image in
                        let fan = Self.fan[index % Self.fan.count]
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 150)
                            .photoFrame(frame)
                            // Squared up, like the pile it becomes.
                            .offset(x: fan.x, y: fan.y)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .overlay(alignment: .bottomTrailing) {
                if pickedCount > 0 {
                    Text("\(pickedCount) \(pickedCount == 1 ? "photo" : "photos") · change")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .animation(.spring(duration: 0.4), value: previews.count)
            .animation(.spring(duration: 0.3), value: frame.kind)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [
        (-3, 0, 0), (7, 46, -8), (-9, -48, 6), (4, 18, 14),
    ]

    private func swatch(_ kind: FrameStyle.Kind) -> some View {
        let selected = frame.kind == kind
        var style = frame
        style.kind = kind
        return Button { frame.kind = kind } label: {
            VStack(spacing: 8) {
                Group {
                    if let image = previews.first {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(red: 0.55, green: 0.66, blue: 0.72), Color(red: 0.86, green: 0.74, blue: 0.56)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: 120, height: 120)
                .clipped()
                .photoFrame(style)
                .scaleEffect(0.42)
                .frame(width: 78, height: 88)
                .background(selected ? Color.strewnAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.strewnAccent : .clear, lineWidth: 1.5))
                Text(kind.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.strewnAccent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title) frame")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var createButton: some View {
        Button { Task { await create() } } label: {
            Group {
                if isImporting { ProgressView().tint(Color.onAccent) } else { Text(pickedCount == 0 ? "Choose photos to begin" : "Make the batch") }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(pickedCount == 0 ? Color.secondary : Color.onAccent)
        .controlSize(.large)
        .disabled(pickedCount == 0 || isImporting || google.isRunning)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
    }

    /// Small copies of the first few picks, just for the preview stack.
    private func loadPreviews() async {
        var images: [UIImage] = []
        for item in selection.prefix(Self.fan.count) {
            guard !Task.isCancelled else { return }
            if let image = await PhotoImport.thumbnail(from: item, maxPixelSide: 400) {
                images.append(image)
            }
        }
        for asset in suggestedPicked.prefix(max(0, Self.fan.count - images.count)) {
            guard !Task.isCancelled else { return }
            if let image = await LibraryThumbnails.image(for: asset, maxPixelSide: 400) { images.append(image) }
        }
        for photo in googlePicked.prefix(max(0, Self.fan.count - images.count)) {
            if let image = PhotoImport.thumbnail(at: photo.imageURL, maxPixelSide: 400) { images.append(image) }
        }
        guard !Task.isCancelled else { return }
        previews = images
    }

    private func create() async {
        isImporting = true
        defer { isImporting = false }
        let collectionID = UUID()
        let library = await PhotoImport.photos(from: selection, collectionID: collectionID)
        let suggested = await PhotoImport.photos(from: suggestedPicked, collectionID: collectionID)
        let photos = (library + suggested + googlePicked).enumerated().map { index, photo in
            var photo = photo
            photo.collectionID = collectionID
            photo.sortIndex = index
            return photo
        }
        model.createPile(title: title.isEmpty ? "Untitled batch" : title, place: place, photos: photos, frame: frame)
        dismiss()
    }
}

/// Copies picked library photos into the app and makes Photos of them. Dimensions, orientation,
/// capture date and EXIF are read straight from the exported image file rather than requiring
/// PHAsset access, so limited or denied photo library permissions never stretch or degrade photos.
enum PhotoImport {
    private struct PickedImageFile: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .image) { received in
                let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let ext = received.file.pathExtension.isEmpty ? "heic" : received.file.pathExtension
                let destination = dir.appending(path: "\(UUID().uuidString).\(ext)")
                try FileManager.default.copyItem(at: received.file, to: destination)
                return PickedImageFile(url: destination)
            }
        }
    }

    @MainActor
    static func photos(from selection: [PhotosPickerItem], collectionID: UUID) async -> [Photo] {
        let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let canReadAssets = status == .authorized || status == .limited

        var photos: [Photo] = []
        for (index, item) in selection.enumerated() {
            guard let url = await copyImageFile(from: item, into: dir) else { continue }
            let asset = canReadAssets
                ? item.itemIdentifier.flatMap { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject }
                : nil
            let info = metadata(of: url, fallbackAsset: asset)
            photos.append(Photo(id: UUID(), collectionID: collectionID, imageURL: url, rawURL: nil,
                                pixelWidth: info.width, pixelHeight: info.height, caption: nil,
                                capturedAt: info.capturedAt ?? asset?.creationDate, exif: info.exif, sortIndex: index,
                                photosAssetID: item.itemIdentifier))
        }
        return photos
    }

    static func thumbnail(from item: PhotosPickerItem, maxPixelSide: Int) async -> UIImage? {
        let tempDir = FileManager.default.temporaryDirectory
        if let picked = try? await item.loadTransferable(type: PickedImageFile.self) {
            defer { try? FileManager.default.removeItem(at: picked.url) }
            return decodeThumbnail(from: CGImageSourceCreateWithURL(picked.url as CFURL, nil), maxPixelSide: maxPixelSide)
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let fallbackURL = tempDir.appending(path: "\(UUID().uuidString).img")
        if (try? data.write(to: fallbackURL)) != nil {
            defer { try? FileManager.default.removeItem(at: fallbackURL) }
            return decodeThumbnail(from: CGImageSourceCreateWithURL(fallbackURL as CFURL, nil), maxPixelSide: maxPixelSide)
        }
        return decodeThumbnail(from: CGImageSourceCreateWithData(data as CFData, nil), maxPixelSide: maxPixelSide)
    }

    static func thumbnail(at url: URL, maxPixelSide: Int) -> UIImage? {
        decodeThumbnail(from: CGImageSourceCreateWithURL(url as CFURL, nil), maxPixelSide: maxPixelSide)
    }

    private static func decodeThumbnail(from source: CGImageSource?, maxPixelSide: Int) -> UIImage? {
        guard let source else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func copyImageFile(from item: PhotosPickerItem, into dir: URL) async -> URL? {
        if let picked = try? await item.loadTransferable(type: PickedImageFile.self) {
            return picked.url
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let utiExt = source.flatMap { CGImageSourceGetType($0) as String? }.flatMap { UTType($0)?.preferredFilenameExtension }
        let ext = utiExt
            ?? item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension
            ?? item.supportedContentTypes.first?.preferredFilenameExtension
            ?? "heic"
        let url = dir.appending(path: "\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    struct ImageMetadata {
        let width: Int
        let height: Int
        let capturedAt: Date?
        let exif: Photo.Exif?
    }

    static func metadata(of url: URL, fallbackAsset: PHAsset?) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            let w = max(1, fallbackAsset?.pixelWidth ?? 3)
            let h = max(1, fallbackAsset?.pixelHeight ?? 2)
            return ImageMetadata(width: w, height: h, capturedAt: nil, exif: nil)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]

        var rawW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var rawH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if rawW <= 0 || rawH <= 0, let cg = CGImageSourceCreateImageAtIndex(source, index, nil) {
            rawW = cg.width
            rawH = cg.height
        }

        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? (tiff?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
            ?? 1
        let swapped = (5...8).contains(orientation)
        let orientedW = swapped ? rawH : rawW
        let orientedH = swapped ? rawW : rawH

        let width = orientedW > 0 ? orientedW : max(1, fallbackAsset?.pixelWidth ?? 3)
        let height = orientedH > 0 ? orientedH : max(1, fallbackAsset?.pixelHeight ?? 2)

        let exifDict = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let capturedAt = parseExifDate(exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? parseExifDate(exifDict?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? parseExifDate(tiff?[kCGImagePropertyTIFFDateTime] as? String)

        let aperture = (exifDict?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        let exposureTime = (exifDict?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let shutter = exposureTime.flatMap(formatShutter)
        let iso = (exifDict?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let focal = (exifDict?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
            ?? (exifDict?[kCGImagePropertyExifFocalLength] as? NSNumber).map { Int($0.doubleValue.rounded()) }
        let exif: Photo.Exif? = (aperture != nil || shutter != nil || iso != nil || focal != nil)
            ? Photo.Exif(aperture: aperture, shutter: shutter, iso: iso, focalLength: focal)
            : nil

        return ImageMetadata(width: width, height: height, capturedAt: capturedAt, exif: exif)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func parseExifDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return exifDateFormatter.date(from: string)
    }

    static func formatShutter(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        if seconds >= 1 {
            return seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
        }
        let denom = Int((1.0 / seconds).rounded())
        return denom > 0 ? "1/\(denom)" : nil
    }
}
