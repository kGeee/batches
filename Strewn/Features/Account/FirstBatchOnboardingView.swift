import PhotosUI
import SwiftUI

/// Step two of onboarding: every new account starts by putting a first batch on the desk and
/// uploading its screen-sized copies, full frame and with location stripped.
struct FirstBatchOnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: [PhotosPickerItem] = []
    @State private var previews: [UIImage] = []
    @State private var loadingPreviews = false
    @State private var title = ""
    @State private var place = ""
    @State private var frame = FrameStyle()
    @State private var visibility = PhotoCollection.Visibility.private
    @State private var uploadPhase: UploadPhase?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, place }

    private enum UploadPhase: Equatable {
        case importing
        case uploading(done: Int, total: Int)
    }

    private var isBusy: Bool { uploadPhase != nil }

    private var greetingTitle: String {
        if let raw = model.me?.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = raw.split(separator: " ").first, !first.isEmpty {
            return "Welcome, \(first). Start with a batch."
        }
        return "Start with your first batch"
    }

    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [
        (-3, 0, 0), (7, 46, -8), (-9, -48, 6), (4, 18, 14),
    ]

    private static let sampleCards: [(colors: [Color], width: CGFloat, height: CGFloat, angle: Double, x: CGFloat, y: CGFloat)] = [
        ([Color(red: 0.42, green: 0.56, blue: 0.66), Color(red: 0.84, green: 0.68, blue: 0.50)], 148, 98, 9, 34, -10),
        ([Color(red: 0.28, green: 0.44, blue: 0.40), Color(red: 0.74, green: 0.78, blue: 0.72)], 96, 128, -9, -36, 4),
        ([Color(red: 0.34, green: 0.36, blue: 0.54), Color(red: 0.88, green: 0.58, blue: 0.34)], 144, 102, -2, 2, 10),
    ]

    private static let audienceChoices: [(value: PhotoCollection.Visibility, title: String, detail: String, symbol: String)] = [
        (.private, "Only me", "Private on your desk until you share it.", "lock"),
        (.followers, "Followers", "Everyone who follows you can open it.", "person.3"),
        (.public, "Anyone on Batches", "Shows on your profile and opens by link.", "globe"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(
                title: "First batch",
                cancelTitle: isBusy ? nil : "Sign out",
                onCancel: { Task { await model.signOut() } },
                confirmTitle: isBusy ? nil : "Later",
                confirmEnabled: !isBusy,
                onConfirm: { model.completeFirstBatchOnboarding() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    pilePicker
                    detailsSection
                    frameSection
                    audienceSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .sensoryFeedback(.selection, trigger: frame.kind)
        .sensoryFeedback(.selection, trigger: visibility)
        .task(id: selection) { await loadPreviews() }
    }

    // MARK: Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEP 2 OF 2 · START YOUR DESK").metaStyle(.caption)
            Text(greetingTitle)
                .titleStyle(.title2, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a handful of shots from a trip, an afternoon or a roll. Every photo stays full frame — nothing is cropped.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pilePicker: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: 60,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            ZStack {
                if previews.isEmpty {
                    emptyPileStage
                } else {
                    ForEach(Array(previews.enumerated().reversed()), id: \.offset) { index, image in
                        let spot = Self.fan[index % Self.fan.count]
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 152)
                            .photoFrame(frame, frameNumber: index + 1)
                            .rotationEffect(.degrees(spot.angle))
                            .offset(x: spot.x, y: spot.y)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 268)
            .overlay(alignment: .bottomTrailing) {
                if !selection.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.stack")
                        Text("\(selection.count.counted("photo")) · change")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .animation(.spring(duration: 0.4), value: previews.count)
            .animation(.spring(duration: 0.3), value: frame.kind)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(selection.isEmpty ? "Choose photos from your library" : "\(selection.count.counted("photo")) selected. Double-tap to change.")
    }

    private var emptyPileStage: some View {
        ZStack {
            ForEach(Array(Self.sampleCards.enumerated()), id: \.offset) { index, sample in
                LinearGradient(colors: sample.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: sample.width, height: sample.height)
                    .photoFrame(frame, frameNumber: index + 1)
                    .rotationEffect(.degrees(sample.angle))
                    .offset(x: sample.x, y: sample.y)
                    .opacity(0.68)
            }

            VStack(spacing: 8) {
                if loadingPreviews {
                    ProgressView()
                        .tint(.strewnAccent)
                    Text("Reading photos…")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Tap to choose photos")
                        .font(.headline)
                    Text("Up to 60 · shown whole")
                        .metaStyle()
                }
            }
            .foregroundStyle(Color.strewnAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.strewnAccent.opacity(0.45), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                PaperLabel("Batch name").padding(.horizontal, 4)
                TextField("Big Sur, one afternoon", text: $title)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .place }
                    .disabled(isBusy)
                    .paperField(focused: focusedField == .title)
            }

            VStack(alignment: .leading, spacing: 8) {
                PaperLabel("Place").padding(.horizontal, 4)
                TextField("Where it was shot (optional)", text: $place)
                    .focused($focusedField, equals: .place)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .disabled(isBusy)
                    .paperField(focused: focusedField == .place)
            }
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperLabel("Frame").padding(.horizontal, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(FrameStyle.Kind.allCases) { kind in
                        swatch(kind)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func swatch(_ kind: FrameStyle.Kind) -> some View {
        let selected = frame.kind == kind
        var style = frame
        style.kind = kind
        return Button {
            frame.kind = kind
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let image = previews.first {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(red: 0.55, green: 0.66, blue: 0.72), Color(red: 0.86, green: 0.74, blue: 0.56)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
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
        .disabled(isBusy)
        .accessibilityLabel("\(kind.title) frame")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var audienceSection: some View {
        PaperSection(
            title: "Who can see it",
            footer: "Screen-sized copies without location are uploaded to your account. Originals stay in your Photos library."
        ) {
            ForEach(Array(Self.audienceChoices.enumerated()), id: \.element.value) { index, option in
                if index > 0 { PaperDivider(inset: 52) }
                PaperChoiceRow(
                    title: option.title,
                    detail: option.detail,
                    symbol: option.symbol,
                    selected: visibility == option.value
                ) {
                    withAnimation(.snappy(duration: 0.2)) { visibility = option.value }
                }
                .disabled(isBusy)
            }
        }
    }

    // MARK: Bottom CTA & Upload Progress

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let uploadPhase {
                uploadStatusRow(uploadPhase)
            }

            if selection.isEmpty && !isBusy {
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: 60,
                    matching: .images,
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    Label("Choose photos to begin", systemImage: "photo.on.rectangle.angled")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.strewnAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await uploadFirstBatch() }
                } label: {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().tint(Color.onAccent)
                            Text("Uploading batch…")
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Upload batch · \(selection.count.counted("photo"))")
                        }
                    }
                }
                .buttonStyle(.paper(.primary))
                .disabled(selection.isEmpty || isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func uploadStatusRow(_ phase: UploadPhase) -> some View {
        switch phase {
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing full-frame photos…").metaStyle(.caption)
                Spacer()
            }
        case .uploading(let done, let total):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Uploading \(min(done + 1, max(1, total))) of \(total)…").metaStyle(.caption)
                    Spacer()
                    Text("\(Int((Double(done) / Double(max(1, total)) * 100).rounded()))%").metaStyle(.caption)
                }
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .tint(.strewnAccent)
            }
        }
    }

    // MARK: Actions

    private func loadPreviews() async {
        guard !selection.isEmpty else {
            previews = []
            loadingPreviews = false
            return
        }
        loadingPreviews = true
        var images: [UIImage] = []
        for item in selection.prefix(Self.fan.count) {
            guard !Task.isCancelled else { return }
            if let image = await PhotoImport.thumbnail(from: item, maxPixelSide: 420) {
                images.append(image)
            }
        }
        guard !Task.isCancelled else { return }
        previews = images
        loadingPreviews = false
    }

    private func uploadFirstBatch() async {
        guard !selection.isEmpty, !isBusy else { return }
        focusedField = nil
        uploadPhase = .importing
        let collectionID = UUID()
        let photos = await PhotoImport.photos(from: selection, collectionID: collectionID)
        guard !photos.isEmpty else {
            uploadPhase = nil
            model.errorMessage = "Couldn't read those photos from your library. Try picking again."
            return
        }
        uploadPhase = .uploading(done: 0, total: photos.count)
        await model.createAndUploadFirstBatch(
            title: title,
            place: place,
            photos: photos,
            frame: frame,
            visibility: visibility
        ) { done, total in
            uploadPhase = .uploading(done: done, total: total)
        }
        uploadPhase = nil
    }
}
