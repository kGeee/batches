import Photos
import PhotosUI
import SwiftUI

/// Start a pile from the Photos library with the system picker. The chosen photos sit on the
/// linen as a loose stack in the frame you pick, so you see the pile before you make it.
struct NewPileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: [PhotosPickerItem] = []
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
                    picker
                    VStack(alignment: .leading, spacing: 6) {
                        label("Name")
                        TextField("Big Sur, one afternoon", text: $title)
                            .font(.system(.title2, design: .serif, weight: .semibold))
                            .focused($naming)
                            .submitLabel(.done)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(naming ? 0.5 : 0.18)).frame(height: 1) }
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
        .task(id: selection) { await loadPreviews() }
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
                            .scaledToFill()
                            .frame(width: 150, height: 150 * image.size.height / max(image.size.width, 1))
                            .clipped()
                            .photoFrame(frame)
                            // Squared up, like the pile it becomes.
                            .offset(x: fan.x, y: fan.y)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .overlay(alignment: .bottomTrailing) {
                if !selection.isEmpty {
                    Text("\(selection.count) \(selection.count == 1 ? "photo" : "photos") · change")
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
                if isImporting { ProgressView().tint(Color.onAccent) } else { Text(selection.isEmpty ? "Choose photos to begin" : "Make the batch") }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(selection.isEmpty ? Color.secondary : Color.onAccent)
        .controlSize(.large)
        .disabled(selection.isEmpty || isImporting)
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
            guard let data = try? await item.loadTransferable(type: Data.self), let full = UIImage(data: data) else { continue }
            let scale = 400 / max(full.size.width, full.size.height, 1)
            guard let image = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * scale, height: full.size.height * scale))
            else { continue }
            images.append(image)
        }
        guard !Task.isCancelled else { return }
        previews = images
    }

    private func create() async {
        isImporting = true
        defer { isImporting = false }
        let photos = await PhotoImport.photos(from: selection, collectionID: UUID())
        model.createPile(title: title.isEmpty ? "Untitled batch" : title, photos: photos, frame: frame)
        dismiss()
    }
}

/// Copies picked library photos into the app and makes Photos of them. Pixel sizes come from
/// the PHAsset, so each photo lays out full frame before its file loads. Used by New pile and
/// by Add photos in the gallery.
enum PhotoImport {
    @MainActor
    static func photos(from selection: [PhotosPickerItem], collectionID: UUID) async -> [Photo] {
        // Needed to read pixel sizes and to write edits back to these assets later.
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var photos: [Photo] = []
        for (index, item) in selection.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let asset = item.itemIdentifier.flatMap { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject }
            let size = asset.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) } ?? pixelSize(of: data)
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "heic"
            let url = dir.appending(path: "\(UUID().uuidString).\(ext)")
            do { try data.write(to: url) } catch { continue }
            photos.append(Photo(id: UUID(), collectionID: collectionID, imageURL: url, rawURL: nil,
                                pixelWidth: Int(size.width), pixelHeight: Int(size.height), caption: nil,
                                capturedAt: asset?.creationDate, exif: nil, sortIndex: index,
                                photosAssetID: item.itemIdentifier))
        }
        return photos
    }

    private static func pixelSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return CGSize(width: 3, height: 2) }
        return CGSize(width: w, height: h)
    }
}
