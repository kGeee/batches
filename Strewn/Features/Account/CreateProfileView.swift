import SwiftUI

/// After the first sign-in: pick the handle people find you by and the name they see.
struct CreateProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var displayName = ""
    @State private var handle = ""
    @State private var available: Bool?
    @State private var working = false
    @State private var problem: String?

    @FocusState private var focus: Field?
    private enum Field { case name, handle }

    var body: some View {
        PaperSheet(title: "Make your profile", cancelTitle: "Sign out", onCancel: { Task { await model.signOut() } },
                   confirmTitle: "Continue", confirmEnabled: canContinue, confirmBusy: working, onConfirm: create) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How people find you").titleStyle(.title2, weight: .bold)
                Text("Friends search for your name or handle.").font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                PaperLabel("Name").padding(.horizontal, 4)
                TextField("Your name", text: $displayName)
                    .textContentType(.name)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .handle }
                    .paperField(focused: focus == .name)
            }
            VStack(alignment: .leading, spacing: 10) {
                PaperLabel("Handle").padding(.horizontal, 4)
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("handle", text: $handle)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .handle)
                        .submitLabel(.go)
                        .onSubmit { if canContinue { create() } }
                        .onChange(of: handle) { _, new in
                            let cleaned = String(new.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }.prefix(24))
                            if cleaned != new { handle = cleaned }
                        }
                    Spacer()
                    handleStatus
                }
                .paperField(focused: focus == .handle)
                Text("3 to 24 lowercase letters, numbers, dots or underscores.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
        }
        .onAppear { focus = .name }
        .task(id: handle) {
            available = nil
            guard User.isValidHandle(handle) else { return }
            try? await Task.sleep(for: .milliseconds(350))   // wait until typing pauses
            guard !Task.isCancelled else { return }
            available = await model.isHandleAvailable(handle)
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
