import SwiftUI

/// Search for people by name or handle, follow them, or open their desk.
struct FindPeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [User] = []

    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Name or @handle", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searching)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
                .paperField(focused: searching)

                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 30)
                } else if !results.isEmpty {
                    PaperSection {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, user in
                            if index > 0 { PaperDivider(inset: 66) }
                            PeopleListRow(user: user)
                        }
                    }
                }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskMatBackground())
        .paperNavigationTitle("Find people")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            results = await model.search(query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")))
        }
    }
}

/// A person in a list: tap to open their desk, follow from the button. Not for yourself.
struct PeopleListRow: View {
    let user: User
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink(value: user) {
                HStack(spacing: 12) {
                    AvatarView(user: user, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.displayName).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text("@\(user.handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if user.id != model.me?.id { FollowButton(user: user) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct PersonRow<Trailing: View>: View {
    let user: User
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(user: user, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName).font(.body.weight(.semibold))
                Text("@\(user.handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }
}
