import SwiftUI

/// Tag people on a photo (optionally tapping a spot on the full-frame image to pin their handle),
/// see who's in a photo, or remove your own tag.
struct PhotoTagsSheet: View {
    let photo: Photo
    let collection: PhotoCollection
    let canManageTags: Bool
    var initialTags: [PhotoTag] = []
    var onOpenUser: ((User) -> Void)? = nil
    var onTagsChange: ([PhotoTag]) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [PhotoTag]
    @State private var pinPoint: CGPoint?
    @State private var query = ""
    @State private var suggestions: [User] = []
    @State private var candidates: [User] = []
    @State private var problem: String?
    @State private var busyID: UUID?
    @FocusState private var searching: Bool

    init(photo: Photo, collection: PhotoCollection, canManageTags: Bool, initialTags: [PhotoTag] = [],
         onOpenUser: ((User) -> Void)? = nil, onTagsChange: @escaping ([PhotoTag]) -> Void = { _ in }) {
        self.photo = photo
        self.collection = collection
        self.canManageTags = canManageTags
        self.initialTags = initialTags
        self.onOpenUser = onOpenUser
        self.onTagsChange = onTagsChange
        _tags = State(initialValue: initialTags)
    }

    var body: some View {
        PaperSheet(title: canManageTags ? "Tag people" : "In this photo", cancelTitle: nil,
                   confirmTitle: "Done", onConfirm: { dismiss() }) {
            photoPreview

            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4)
            }

            if !tags.isEmpty {
                PaperSection(title: "Tagged") {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        if index > 0 { PaperDivider(inset: 62) }
                        taggedRow(tag)
                    }
                }
            } else if !canManageTags {
                Text("Nobody is tagged in this photo.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
            }

            if canManageTags {
                pickerSection
            }
        }
        .task { await loadDefaultCandidates() }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            guard !trimmed.isEmpty else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            suggestions = await model.search(trimmed)
        }
    }

    // MARK: Full-frame preview & pin placement

    private var photoPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotoImage(photo: photo)
                .overlay {
                    GeometryReader { geo in
                        ZStack {
                            if canManageTags {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onEnded { value in
                                                guard geo.size.width > 0, geo.size.height > 0 else { return }
                                                let nx = min(0.96, max(0.04, value.location.x / geo.size.width))
                                                let ny = min(0.96, max(0.04, value.location.y / geo.size.height))
                                                withAnimation(.snappy(duration: 0.2)) {
                                                    pinPoint = CGPoint(x: nx, y: ny)
                                                }
                                                searching = true
                                            }
                                    )
                            }
                            ForEach(tags) { tag in
                                if let x = tag.x, let y = tag.y {
                                    PhotoTagPin(handle: tag.user?.handle ?? "tagged",
                                                point: CGPoint(x: x, y: y),
                                                in: geo.size) {
                                        if let user = tag.user, let onOpenUser {
                                            dismiss()
                                            onOpenUser(user)
                                        }
                                    }
                                }
                            }
                            if let pinPoint {
                                Circle()
                                    .fill(Color.strewnAccent)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.paper, lineWidth: 2.5))
                                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                                    .position(x: pinPoint.x * geo.size.width, y: pinPoint.y * geo.size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity)

            if canManageTags {
                HStack {
                    Text(pinPoint == nil
                         ? "Tap anywhere on the photo to place a pin, or pick someone below."
                         : "Pin placed — choose who's there below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if pinPoint != nil {
                        Button("Clear pin") { withAnimation(.snappy) { pinPoint = nil } }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func taggedRow(_ tag: PhotoTag) -> some View {
        let canRemove = canManageTags || tag.userID == model.me?.id || tag.taggedBy == model.me?.id
        return PaperRow {
            HStack(spacing: 12) {
                Button {
                    if let user = tag.user, let onOpenUser {
                        dismiss()
                        onOpenUser(user)
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(user: tag.user, size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tag.user?.displayName ?? "Someone").font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if let handle = tag.user?.handle {
                                Text("@\(handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpenUser == nil || tag.user == nil)

                Spacer()

                if busyID == tag.userID {
                    ProgressView()
                } else if canRemove {
                    Button(tag.userID == model.me?.id && !canManageTags ? "Remove me" : "Remove") {
                        remove(tag)
                    }
                    .buttonStyle(.paper(.secondary, compact: true))
                }
            }
        }
    }

    private var pickerSection: some View {
        let taggedIDs = Set(tags.map(\.userID))
        let list = (query.trimmingCharacters(in: .whitespaces).isEmpty ? candidates : suggestions)
            .filter { !taggedIDs.contains($0.id) }

        return PaperSection(title: pinPoint == nil ? "Add someone" : "Who's at this pin?",
                            footer: "People you tag are notified once they can view this batch. Anyone tagged can remove themselves.") {
            PaperRow {
                HStack(spacing: 10) {
                    Image(systemName: "at").font(.subheadline.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                        .frame(width: 30, height: 30)
                        .background(Color.strewnAccent.opacity(0.12), in: Circle())
                    TextField("Search name or @handle", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searching)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
            }
            ForEach(list.prefix(12)) { person in
                PaperDivider(inset: 62)
                Button { add(person) } label: {
                    PaperRow {
                        PersonRow(user: person) {
                            if busyID == person.id {
                                ProgressView()
                            } else {
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.strewnAccent)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busyID != nil)
                .accessibilityLabel("Tag \(person.displayName)")
            }
        }
    }

    private func loadDefaultCandidates() async {
        guard canManageTags, let me = model.me else { return }
        var seen: Set<UUID> = []
        var people: [User] = []
        func append(_ user: User?) {
            guard let user, !model.isBlocked(user), seen.insert(user.id).inserted else { return }
            people.append(user)
        }
        collection.sharedWith.forEach(append)
        collection.contributors.forEach(append)
        append(collection.owner)
        if let following = try? await model.following(of: me) { following.forEach(append) }
        if let followers = try? await model.followers(of: me) { followers.forEach(append) }
        append(me)
        candidates = people
    }

    private func add(_ person: User) {
        problem = nil
        busyID = person.id
        let point = pinPoint
        Task {
            do {
                let tag = try await model.setTag(user: person, x: point.map { Double($0.x) }, y: point.map { Double($0.y) }, on: photo.id)
                withAnimation(.snappy) {
                    tags.removeAll { $0.userID == person.id }
                    tags.append(tag)
                    pinPoint = nil
                    query = ""
                }
                onTagsChange(tags)
            } catch {
                problem = "Couldn't tag @\(person.handle). Try again."
            }
            busyID = nil
        }
    }

    private func remove(_ tag: PhotoTag) {
        problem = nil
        busyID = tag.userID
        let before = tags
        withAnimation(.snappy) { tags.removeAll { $0.userID == tag.userID } }
        onTagsChange(tags)
        Task {
            do {
                try await model.removeTag(userID: tag.userID, from: photo.id)
            } catch {
                tags = before
                onTagsChange(before)
                problem = "Couldn't remove that tag."
            }
            busyID = nil
        }
    }
}

/// A small translucent pill anchored at a normalized point on a full-frame photo, clamped inside
/// the photo's bounds so edge pins never clip.
struct PhotoTagPin: View {
    let handle: String
    let point: CGPoint
    let size: CGSize
    var action: (() -> Void)? = nil

    init(handle: String, point: CGPoint, in size: CGSize, action: (() -> Void)? = nil) {
        self.handle = handle
        self.point = point
        self.size = size
        self.action = action
    }

    var body: some View {
        let clampedX = min(max(point.x * size.width, 44), max(44, size.width - 44))
        let clampedY = min(max(point.y * size.height, 20), max(20, size.height - 20))
        Button { action?() } label: {
            Text("@\(handle)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .position(x: clampedX, y: clampedY)
        .accessibilityLabel("Tagged @\(handle)")
    }
}
