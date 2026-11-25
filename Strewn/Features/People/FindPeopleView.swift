import SwiftUI

/// Search for people by name or handle, follow them, or open their desk.
struct FindPeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [User] = []

    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Find people").titleStyle(.largeTitle)
                    .accessibilityAddTraits(.isHeader)
                // A search line on the fog, not a box: a hairline that darkens while you type.
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Name or @handle", text: $query)
                        .font(.system(.title3, design: .serif))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searching)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(searching ? 0.5 : 0.15)).frame(height: 1)
                }
                .animation(.easeOut(duration: 0.2), value: searching)

                if results.isEmpty {
                    Text(query.isEmpty ? "Look for a friend by their name or @handle." : "No one called \u{201C}\(query)\u{201D} yet.")
                        .font(.system(.callout, design: .serif).italic())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, user in
                            if index > 0 { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
                            PeopleListRow(user: user)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskMatBackground())
        .navigationTitle("Find people")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .principal) { Text("") } }
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
                    AvatarView(user: user, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text("@\(user.handle)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if user.id != model.me?.id { FollowButton(user: user) }
        }
        .padding(.vertical, 12)
    }
}

struct PersonRow<Trailing: View>: View {
    let user: User
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(user: user, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName).font(.body.weight(.medium))
                Text("@\(user.handle)").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }
}
