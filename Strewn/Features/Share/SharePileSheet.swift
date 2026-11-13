import SwiftUI

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

    var body: some View {
        PaperSheet(title: "Share batch", onCancel: { dismiss() }, confirmTitle: "Done",
                   confirmEnabled: !(visibility == .people && people.isEmpty), confirmBusy: saving, onConfirm: save) {
            PaperSection(title: "Who can see this batch") {
                ForEach(Array(PhotoCollection.Visibility.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 { PaperDivider(inset: 52) }
                    PaperChoiceRow(title: option.title, detail: option.detail, symbol: option.symbol,
                                   selected: visibility == option) { withAnimation(.snappy) { visibility = option } }
                }
            }

            if visibility == .people || visibility == .followers {
                PaperSection(title: visibility == .people ? "People" : "Also share with",
                             footer: (visibility == .people
                                      ? "Only these people can open the batch. They see it in their feed."
                                      : "People who don't follow you can still see it if you add them here.")
                                     + " Anyone who can add photos makes this a group batch: they can add and remove their own photos; the name, cover and sharing stay yours.") {
                    ForEach(people) { person in
                        PaperRow {
                            VStack(alignment: .leading, spacing: 8) {
                                PersonRow(user: person) {
                                    Button {
                                        withAnimation(.snappy) {
                                            people.removeAll { $0.id == person.id }
                                            canAdd.remove(person.id)
                                        }
                                    } label: {
                                        Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                                            .frame(width: 30, height: 30)
                                            .background(Color.secondary.opacity(0.15), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(person.displayName)")
                                }
                                Toggle(isOn: Binding(get: { canAdd.contains(person.id) },
                                                     set: { if $0 { canAdd.insert(person.id) } else { canAdd.remove(person.id) } })) {
                                    Label("Can add photos", systemImage: "plus.rectangle.on.rectangle").font(.subheadline)
                                }
                                .toggleStyle(.paper)
                                .padding(.leading, 52)
                            }
                        }
                        PaperDivider()
                    }
                    PaperRow {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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

            if let pile, pile.isShared, visibility != .private {
                PaperSection(footer: "The link opens this batch in the app for anyone who can already see it.") {
                    ShareLink(item: AppModel.link(to: pile), subject: Text(pile.title),
                              message: Text("\(pile.title), on Batches")) {
                        PaperRow {
                            Label("Send a link", systemImage: "link").foregroundStyle(Color.strewnAccent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if visibility != .private {
                Text("Sharing uploads small copies of each photo, sized for phones, without location data. Your RAW files and originals stay on this phone.")
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
        .task(id: query) {
            guard !query.isEmpty else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            matches = await model.search(query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")))
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
