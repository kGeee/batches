import SwiftUI
import UIKit

/// Who can see a pile: only you, specific people, your followers, or anyone on Strewn, and
/// which of the people you add may add their own photos (a group pile).
/// Saving uploads small copies of each photo for viewers; RAW files never leave the phone.
struct SharePileSheet: View {
    let collectionID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var visibility = PhotoCollection.Visibility.private
    @State private var people: [User] = []
    @State private var canAdd: Set<UUID> = []
    @State private var query = ""
    @State private var matches: [User] = []
    @State private var saving = false

    private var pile: PhotoCollection? { model.myCollections.first { $0.id == collectionID } }

    @FocusState private var searching: Bool

    /// Who follows you, to count how many people a followers batch reaches. nil until loaded.
    @State private var followers: [User]?
    @State private var copied = false

    private let grid = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        PaperSheet(title: "Share batch", onCancel: { dismiss() }, confirmTitle: "Done",
                   confirmEnabled: !(visibility == .people && people.isEmpty), confirmBusy: saving, onConfirm: save) {
            VStack(alignment: .leading, spacing: 10) {
                PaperLabel("Who can see it").padding(.horizontal, 4)
                LazyVGrid(columns: grid, spacing: 8) {
                    ForEach(PhotoCollection.Visibility.allCases) { option in audienceCard(option) }
                }
                reach.padding(.horizontal, 4).padding(.top, 2)
            }

            if visibility == .people || visibility == .followers {
                PaperSection(title: visibility == .people ? "People" : "Also shared with",
                             footer: people.isEmpty ? nil
                                : "People who can add photos can add and remove their own. The name, cover and sharing stay yours.") {
                    ForEach(people) { person in
                        PaperRow { PersonRow(user: person) { roleMenu(person) } }
                        PaperDivider()
                    }
                    PaperRow {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                                .frame(width: 32, height: 32)
                                .background(Color.strewnAccent.opacity(0.12), in: Circle())
                            TextField("Add by name or @handle", text: $query)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($searching)
                                .submitLabel(.search)
                        }
                    }
                    ForEach(matches.filter { m in !people.contains { $0.id == m.id } }) { match in
                        PaperDivider()
                        Button {
                            withAnimation(.snappy) { people.append(match) }
                            query = ""
                        } label: {
                            PaperRow {
                                PersonRow(user: match) {
                                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.strewnAccent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(match.displayName)")
                    }
                }
            }

            if let pile, pile.isShared, visibility != .private { linkSection(pile) }

            if visibility != .private {
                Label("Small copies only, without location. RAW files and originals stay on this phone.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
            guard let pile else { return }
            visibility = pile.visibility
            people = pile.sharedWith
            canAdd = pile.contributorIDs
        }
        .task {
            if let me = model.me { followers = try? await model.followers(of: me) }
        }
        .task(id: query) {
            guard !query.isEmpty else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            matches = await model.search(query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")))
        }
    }

    // MARK: Audience

    private func audienceCard(_ option: PhotoCollection.Visibility) -> some View {
        let selected = visibility == option
        return Button {
            withAnimation(.snappy) { visibility = option }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: option.symbol).font(.body.weight(.medium)).foregroundStyle(Color.strewnAccent)
                        .frame(height: 22)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Color.strewnAccent) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                }
                Text(option.shortTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).padding(.top, 4)
                Text(option.brief).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.strewnAccent, lineWidth: selected ? 2 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title). \(option.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What the choice comes to: how many people can open the batch, and who.
    private var reach: some View {
        let faces: [User]
        let count: Int?
        let rest: String
        switch visibility {
        case .private:
            (faces, count, rest) = ([], nil, "Only you. It stays on your desk.")
        case .public:
            (faces, count, rest) = ([], nil, "Anyone signed in to Batches can open this.")
        case .people:
            (faces, count, rest) = (people, people.isEmpty ? nil : people.count,
                                    people.isEmpty ? "Add at least one person below." : " can open this.")
        case .followers:
            if let followers {
                let following = Set(followers.map(\.id))
                let extra = people.filter { !following.contains($0.id) }
                var line = " can open this: \(followers.count.counted("follower"))"
                if !extra.isEmpty { line += ", plus " + ListFormatter.localizedString(byJoining: extra.map(\.displayName)) }
                (faces, count, rest) = (extra + followers, followers.count + extra.count, line + ".")
            } else {
                (faces, count, rest) = (people, nil, "Everyone who follows you, plus anyone you add.")
            }
        }
        return HStack(spacing: 9) {
            if !faces.isEmpty {
                HStack(spacing: -8) {
                    ForEach(faces.prefix(3)) { AvatarView(user: $0, size: 26) }
                }
            }
            (Text(count.map { $0.counted("person", plural: "people") } ?? "").fontWeight(.semibold).foregroundStyle(.primary) + Text(rest))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// What one person may do, and the way to take them off the list.
    private func roleMenu(_ person: User) -> some View {
        let adds = canAdd.contains(person.id)
        return Menu {
            Picker("Role", selection: Binding(get: { canAdd.contains(person.id) },
                                              set: { if $0 { canAdd.insert(person.id) } else { canAdd.remove(person.id) } })) {
                Label("Can add photos", systemImage: "plus.rectangle.on.rectangle").tag(true)
                Label("Can view", systemImage: "eye").tag(false)
            }
            Button("Remove", systemImage: "xmark", role: .destructive) {
                withAnimation(.snappy) {
                    people.removeAll { $0.id == person.id }
                    canAdd.remove(person.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if adds { Image(systemName: "plus.rectangle.on.rectangle") }
                Text(adds ? "Can add photos" : "Can view")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(adds ? AnyShapeStyle(Color.strewnAccent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(adds ? Color.strewnAccent.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("\(person.displayName): \(adds ? "can add photos" : "can view")")
    }

    // MARK: Link

    /// The link as the person you send it to will see it, with the two things you do with one.
    private func linkSection(_ pile: PhotoCollection) -> some View {
        let url = AppModel.link(to: pile)
        return VStack(alignment: .leading, spacing: 8) {
            PaperLabel("Link").padding(.horizontal, 4)
            HStack(spacing: 12) {
                if let cover = pile.cover {
                    // The whole cover, small: never cropped to a square.
                    PhotoImage(photo: cover)
                        .frame(maxWidth: 76, maxHeight: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pile.title).batchTitle(pile.font, .subheadline).lineLimit(1)
                    Text("\(pile.photos.count.counted("frame")) · by \(model.me?.displayName ?? "you")").metaStyle().lineLimit(1)
                    Text(AppModel.webHost).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.url = url
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                }
                .buttonStyle(.paper(.secondary))
                .sensoryFeedback(.success, trigger: copied) { _, now in now }
                LinkShareButton(url: url, title: pile.title, photo: pile.cover) {
                    Label("Send", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.paper(.primary))
            }
            Text("It opens this batch for anyone who can already see it.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func save() {
        saving = true
        let kept = (visibility == .people || visibility == .followers) ? people : []
        Task {
            await model.setSharing(visibility, people: kept, canAdd: canAdd, for: collectionID)
            saving = false
            dismiss()
        }
    }
}
