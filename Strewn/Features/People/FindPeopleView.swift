import SwiftUI

/// Search for people by name or handle, follow them, or open their desk.
struct FindPeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [User] = []

    var body: some View {
        List(results) { user in
            NavigationLink(value: user) {
                PersonRow(user: user) { FollowButton(user: user) }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DeskMatBackground())
        .overlay {
            if results.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("Find people")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or @handle")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            results = await model.search(query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")))
        }
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
