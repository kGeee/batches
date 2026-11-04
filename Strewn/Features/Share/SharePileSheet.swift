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

    var body: some View {
        NavigationStack {
            Form {
                Section("Who can see this batch") {
                    ForEach(PhotoCollection.Visibility.allCases) { option in
                        Button { visibility = option } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol).frame(width: 26).foregroundStyle(Color.strewnAccent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if visibility == option { Image(systemName: "checkmark").foregroundStyle(Color.strewnAccent) }
                            }
                        }
                        .accessibilityAddTraits(visibility == option ? .isSelected : [])
                    }
                }

                if visibility == .people || visibility == .followers {
                    Section {
                        ForEach(people) { person in
                            VStack(alignment: .leading, spacing: 8) {
                                PersonRow(user: person) {
                                    Button("Remove", systemImage: "minus.circle.fill") {
                                        people.removeAll { $0.id == person.id }
                                        canAdd.remove(person.id)
                                    }
                                    .labelStyle(.iconOnly).foregroundStyle(.red).buttonStyle(.borderless)
                                }
                                Toggle(isOn: Binding(get: { canAdd.contains(person.id) },
                                                     set: { if $0 { canAdd.insert(person.id) } else { canAdd.remove(person.id) } })) {
                                    Label("Can add photos", systemImage: "plus.rectangle.on.rectangle").font(.subheadline)
                                }
                                .tint(.strewnAccent)
                                .padding(.leading, 52)
                            }
                        }
                        TextField("Add by name or @handle", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        ForEach(matches.filter { m in !people.contains { $0.id == m.id } }) { match in
                            Button { people.append(match); query = "" } label: {
                                PersonRow(user: match) { Image(systemName: "plus.circle").foregroundStyle(Color.strewnAccent) }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(visibility == .people ? "People" : "Also share with")
                    } footer: {
                        Text((visibility == .people
                             ? "Only these people can open the batch. They see it in their feed."
                             : "People who don't follow you can still see it if you add them here.")
                             + " Anyone who can add photos makes this a group batch: they can add and remove their own photos; the name, cover and sharing stay yours.")
                    }
                }

                if let pile, pile.isShared, visibility != .private {
                    Section {
                        ShareLink(item: AppModel.link(to: pile), subject: Text(pile.title),
                                  message: Text("\(pile.title), on Batches")) {
                            Label("Send a link", systemImage: "link")
                        }
                    } footer: {
                        Text("The link opens this batch in the app for anyone who can already see it.")
                    }
                }

                if visibility != .private {
                    Section {
                    } footer: {
                        Text("Sharing uploads small copies of each photo, sized for phones, without location data. Your RAW files and originals stay on this phone.")
                    }
                }
            }
            .navigationTitle("Share batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).disabled(saving || (visibility == .people && people.isEmpty))
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
