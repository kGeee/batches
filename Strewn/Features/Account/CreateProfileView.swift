import SwiftUI

/// After the first sign-in: pick the handle people find you by and the name they see.
struct CreateProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var displayName = ""
    @State private var handle = ""
    @State private var available: Bool?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName).textContentType(.name)
                    HStack(spacing: 2) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("handle", text: $handle)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: handle) { _, new in
                                let cleaned = String(new.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }.prefix(24))
                                if cleaned != new { handle = cleaned }
                            }
                        Spacer()
                        handleStatus
                    }
                } header: {
                    Text("How people find you")
                } footer: {
                    Text("3 to 24 lowercase letters, numbers, dots or underscores. Friends can search for your name or handle.")
                }
                if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Make your profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: create).disabled(!canContinue)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
            }
            .task(id: handle) {
                available = nil
                guard User.isValidHandle(handle) else { return }
                try? await Task.sleep(for: .milliseconds(350))   // wait until typing pauses
                guard !Task.isCancelled else { return }
                available = await model.isHandleAvailable(handle)
            }
        }
    }

    @ViewBuilder private var handleStatus: some View {
        if handle.isEmpty {
            EmptyView()
        } else if !User.isValidHandle(handle) {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        } else if let available {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? .green : .red)
                .accessibilityLabel(available ? "Available" : "Taken")
        } else {
            ProgressView()
        }
    }

    private var canContinue: Bool {
        !working && available == true && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        working = true
        problem = nil
        Task {
            do { try await model.createProfile(handle: handle, displayName: displayName.trimmingCharacters(in: .whitespaces)) }
            catch { problem = error.localizedDescription }
            working = false
        }
    }
}
