import Photos
import PhotosUI
import SwiftUI

/// Adding photos to a batch you already have. It starts with what the library has from around
/// the batch's own days that isn't in it yet, then the other suggested days and trips (the
/// nearest first), then the whole library and Google Photos, as in New batch.
struct AddPhotosSheet: View {
    let collection: PhotoCollection
    /// Puts the imported photos in the batch: yours, or one you contribute to.
    var onAdd: ([Photo]) async -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var suggestions = SmartBatchSuggestions()
    @State private var nearby: SmartBatch?
    @State private var lookedAround = false
    @State private var reviewing: SmartBatch?
    @State private var selection: [PhotosPickerItem] = []
    @State private var google = GooglePhotosPicking()
    @State private var importing = false
    @State private var progress: (done: Int, total: Int)?

    private static let maxPhotos = 60

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: "Add photos", onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let nearby { aroundSection(nearby) }
                    SuggestedBatchesRow(suggestions: suggestions, frame: collection.frame) { reviewing = $0 }
                    VStack(alignment: .leading, spacing: 4) {
                        PhotosPicker(selection: $selection, maxSelectionCount: Self.maxPhotos, matching: .images,
                                     preferredItemEncoding: .current, photoLibrary: .shared()) {
                            row("Choose from your library", systemImage: "photo.on.rectangle")
                        }
                        if GooglePhotos.isConfigured {
                            if google.isRunning {
                                GooglePhotosStatus(picking: google)
                            } else {
                                Button(action: importFromGoogle) {
                                    HStack(spacing: 10) {
                                        GooglePhotosMark(size: 17)
                                        Text("From Google Photos").font(.body)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                                    }
                                    .frame(minHeight: 48)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .disabled(importing)
        .overlay { if importing { importingNote } }
        .task { await look() }
        .onDisappear { suggestions.stopNaming() }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with new access: look again.
            if phase == .active, SmartBatchSuggestions.currentAccess() != suggestions.access { Task { await look() } }
        }
        .onChange(of: suggestions.access) { _, _ in
            // Access was just granted from the card in the row.
            if suggestions.canSuggest, !lookedAround { Task { await look() } }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            add { await PhotoImport.photos(from: items, collectionID: collection.id) }
        }
        .sheet(item: $reviewing) { batch in
            SmartBatchReviewView(batch: batch, place: batch.id == nearby?.id ? collection.place : suggestions.places[batch.id],
                                 limit: Self.maxPhotos, useTitle: "Add to batch") { assets in
                add { await PhotoImport.photos(from: assets, collectionID: collection.id) { done, total in progress = (done, total) } }
            }
        }
        .googlePhotosAlert(google)
    }

    /// The photos taken around this batch that aren't in it yet, as one pile at the top.
    private func aroundSection(_ batch: SmartBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FROM AROUND THIS BATCH").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
            Text("\(batch.count.counted("photo")) taken \(batch.dateLabel) that aren't in it yet.")
                .font(.system(.callout, design: .serif).italic())
                .foregroundStyle(.secondary)
            Button { reviewing = batch } label: {
                SuggestionCard(batch: batch, place: collection.place)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.body).foregroundStyle(.secondary).frame(width: 22)
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var importingNote: some View {
        VStack(spacing: 10) {
            ProgressView()
            if let progress, progress.total > 1 {
                Text("Adding \(progress.done) of \(progress.total)…").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Adding…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Finds what's around this batch, loads the other suggestions, and keeps the two apart.
    private func look() async {
        let batched = model.batchedAssetIDs
        async let around = SmartBatchSuggestions.around(collection, excluding: batched)
        await suggestions.load(excluding: batched)
        let found = await around
        lookedAround = suggestions.canSuggest
        withAnimation(.snappy) { nearby = found }
        let date = collection.photos.compactMap(\.capturedAt).min() ?? collection.shotOn ?? .now
        suggestions.focus(on: date, setAside: Set(found?.assetIDs ?? []))
    }

    private func importFromGoogle() {
        add { await google.run(collectionID: collection.id) }
    }

    /// Imports, hands the photos to the batch, and closes.
    private func add(_ photos: @escaping () async -> [Photo]) {
        Task {
            importing = true
            defer { importing = false; progress = nil }
            let imported = await photos()
            guard !imported.isEmpty else { return }
            await onAdd(imported)
            dismiss()
        }
    }
}
