import PhotosUI
import SwiftUI

/// Google's four-petal Photos mark, drawn from the same paths as the web's GooglePhotosMark.
struct GooglePhotosMark: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 24
            // One petal (red: a half disk standing on the line from the center straight up, bulging
            // right), then the others turned a quarter at a time around the center.
            var petal = Path()
            petal.move(to: CGPoint(x: 12, y: 12))
            petal.addLine(to: CGPoint(x: 12, y: 2))
            petal.addArc(center: CGPoint(x: 12, y: 7), radius: 5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            petal.closeSubpath()
            let colors: [Color] = [Color(red: 0.918, green: 0.263, blue: 0.208), Color(red: 0.259, green: 0.522, blue: 0.957),
                                   Color(red: 0.204, green: 0.659, blue: 0.325), Color(red: 0.984, green: 0.737, blue: 0.016)]
            for (index, color) in colors.enumerated() {
                let turn = CGAffineTransform(translationX: 12, y: 12).rotated(by: .pi / 2 * CGFloat(index)).translatedBy(x: -12, y: -12)
                context.fill(petal.applying(turn).applying(CGAffineTransform(scaleX: scale, y: scale)), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Runs one Google Photos pick for a view and keeps what to show while it does.
@MainActor
@Observable
final class GooglePhotosPicking {
    private(set) var stage: GooglePhotos.Stage?
    var error: String?
    private var task: Task<[Photo], Never>?

    var isRunning: Bool { stage != nil }

    /// The downloaded picks, or [] if it was cancelled or failed (the failure lands in `error`).
    func run(collectionID: UUID, maxCount: Int = 60) async -> [Photo] {
        guard task == nil else { return [] }
        let task = Task { @MainActor in
            do {
                return try await GooglePhotos.shared.pick(maxCount: maxCount, collectionID: collectionID) { [weak self] in self?.stage = $0 }
            } catch GooglePhotos.Failure.cancelled {
                return []
            } catch is CancellationError {
                return []
            } catch {
                self.error = error.localizedDescription
                return []
            }
        }
        self.task = task
        let photos = await task.value
        self.task = nil
        stage = nil
        return photos
    }

    func cancel() {
        task?.cancel()
        GooglePhotos.shared.closeSheet()
    }
}

/// The status line under a picker while Google Photos is open or importing, with a way out.
struct GooglePhotosStatus: View {
    let picking: GooglePhotosPicking

    var body: some View {
        if let stage = picking.stage {
            HStack(spacing: 10) {
                GooglePhotosMark(size: 16)
                Text(stage.text).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Cancel") { picking.cancel() }.font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

extension View {
    /// Shows a pick's failure as an alert.
    func googlePhotosAlert(_ picking: GooglePhotosPicking) -> some View {
        alert("Google Photos", isPresented: Binding(get: { picking.error != nil }, set: { if !$0 { picking.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(picking.error ?? "")
        }
    }
}

/// An "add photos" control: the system Photos picker, or, when this build has a Google client
/// ID, a menu that offers both the Photos library and Google Photos.
struct PhotoSourcePicker<Label: View>: View {
    @Binding var selection: [PhotosPickerItem]
    var maxCount = 60
    let onGooglePhotos: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var showLibrary = false

    var body: some View {
        if GooglePhotos.isConfigured {
            Menu {
                Button { showLibrary = true } label: { SwiftUI.Label("Photos library", systemImage: "photo.on.rectangle") }
                Button(action: onGooglePhotos) { SwiftUI.Label("Google Photos", systemImage: "g.circle") }
            } label: {
                label()
            }
            .photosPicker(isPresented: $showLibrary, selection: $selection, maxSelectionCount: maxCount, matching: .images,
                          preferredItemEncoding: .current, photoLibrary: .shared())
        } else {
            PhotosPicker(selection: $selection, maxSelectionCount: maxCount, matching: .images,
                         preferredItemEncoding: .current, photoLibrary: .shared(), label: label)
        }
    }
}
