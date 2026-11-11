import SwiftUI

/// Where people reach you and read the privacy policy, from SUPPORT_EMAIL and PRIVACY_POLICY_URL
/// in Config.xcconfig. Either can be left empty, and its row hides.
enum AppLinks {
    static var supportEmail: String? {
        (Bundle.main.object(forInfoDictionaryKey: "StrewnSupportEmail") as? String)
            .flatMap { $0.contains("@") ? $0.trimmingCharacters(in: .whitespaces) : nil }
    }

    static var privacyPolicy: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "StrewnPrivacyPolicyURL") as? String)
            .flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
    }

    static func feedbackMail(about subject: String = "Batches feedback") -> URL? {
        guard let supportEmail else { return nil }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = supportEmail
        parts.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return parts.url
    }
}

/// What a report sheet is about, for `.sheet(item:)`.
struct ReportTarget: Identifiable {
    let id = UUID()
    let subject: String
    let report: Report
    let owner: User?
}

/// Report a person, a batch or a photo. Reports go to the reports table for you to review; the
/// person reported is never told who reported them.
struct ReportSheet: View {
    /// What's reported, e.g. "this photo" or "@maya".
    let subject: String
    let report: Report
    /// Whose it is, so the sheet can offer to block them as well. Nil for your own things.
    let owner: User?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reason: Report.Reason?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var sending = false
    @State private var sent = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Color.strewnAccent)
                            Text("Thanks for telling us").font(.headline)
                            Text("We review every report within a day and remove anything that breaks the rules.\(alsoBlock ? " You won't see each other's batches any more." : "")")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                } else {
                    Section {
                        ForEach(Report.Reason.allCases) { option in
                            Button {
                                reason = option
                            } label: {
                                HStack {
                                    Text(option.label)
                                    Spacer()
                                    if reason == option { Image(systemName: "checkmark").foregroundStyle(Color.strewnAccent) }
                                }
                            }
                            .tint(.primary)
                        }
                    } header: {
                        Text("What's wrong with \(subject)?")
                    }
                    Section("Anything else (optional)") {
                        TextField("Details", text: $details, axis: .vertical).lineLimit(3...6)
                    }
                    if let owner, owner.id != model.me?.id, !model.isBlocked(owner) {
                        Section {
                            Toggle("Also block @\(owner.handle)", isOn: $alsoBlock)
                        } footer: {
                            Text("Neither of you will see the other's batches, and you'll stop following each other.")
                        }
                    }
                    if let problem {
                        Section { Text(problem).foregroundStyle(.red).font(.footnote) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DeskMatBackground())
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sent {
                    // The block waits for Done: it can remove the very batch this sheet sits on.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if alsoBlock, let owner { Task { await model.block(owner) } }
                            dismiss()
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if sending { ProgressView() } else { Button("Send", action: send).disabled(reason == nil) }
                    }
                }
            }
        }
        .tint(.strewnAccent)
    }

    private func send() {
        guard let reason else { return }
        sending = true
        problem = nil
        var report = report
        report.reason = reason
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        report.details = trimmed.isEmpty ? nil : String(trimmed.prefix(1000))
        Task {
            do {
                try await model.report(report)
                withAnimation { sent = true }
            } catch {
                problem = "Couldn't send the report: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}

/// The people you've blocked, with a way to unblock each.
struct BlockedPeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var unblocking: User?

    var body: some View {
        List {
            if model.blocked.isEmpty {
                Text("You haven't blocked anyone. To block someone, open their desk and tap ⋯.")
                    .font(.callout).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(model.blocked) { user in
                HStack(spacing: 12) {
                    AvatarView(user: user, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.displayName)
                        Text("@\(user.handle)").metaStyle()
                    }
                    Spacer()
                    Button("Unblock") { unblocking = user }.buttonStyle(.bordered).controlSize(.small)
                }
                .listRowBackground(Color.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DeskMatBackground())
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unblock @\(unblocking?.handle ?? "")?", isPresented: Binding(get: { unblocking != nil }, set: { if !$0 { unblocking = nil } }),
                            titleVisibility: .visible, presenting: unblocking) { user in
            Button("Unblock") { Task { await model.unblock(user) } }
        } message: { _ in
            Text("You'll be able to see each other's shared batches again. Follows and shares that the block removed don't come back.")
        }
    }
}

/// Deleting your account, behind a typed confirmation because it can't be undone.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var model
    @State private var typed = ""
    @State private var deleting = false
    @State private var problem: String?

    private var handle: String { model.me?.handle ?? "" }
    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == handle && !handle.isEmpty }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This deletes, for good:").font(.headline)
                    bullet("Your profile, @\(handle)")
                    bullet("Every batch you made, for you and everyone you shared it with")
                    bullet("Photos you added to friends' batches")
                    bullet("Who you follow, who follows you, and your shares")
                    Text("The photos on this phone stay in your Photos library.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
            Section {
                TextField(handle, text: $typed)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Type your handle to confirm")
            }
            Section {
                Button(role: .destructive, action: delete) {
                    HStack {
                        Text("Delete my account")
                        Spacer()
                        if deleting { ProgressView() }
                    }
                }
                .disabled(!confirmed || deleting)
            } footer: {
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DeskMatBackground())
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "minus").labelStyle(.titleAndIcon).font(.subheadline)
    }

    private func delete() {
        deleting = true
        problem = nil
        Task {
            do {
                try await model.deleteAccount()
            } catch {
                problem = "Couldn't delete your account: \(error.localizedDescription) Try again, or email us."
            }
            deleting = false
        }
    }
}

/// The ⋯ menu items for someone else's desk: report and block.
struct PersonSafetyMenu: View {
    let user: User
    @Binding var reporting: Bool
    @Binding var confirmingBlock: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { reporting = true } label: { Label("Report @\(user.handle)", systemImage: "flag") }
        if model.isBlocked(user) {
            Button { Task { await model.unblock(user) } } label: { Label("Unblock", systemImage: "hand.raised.slash") }
        } else {
            Button(role: .destructive) { confirmingBlock = true } label: { Label("Block", systemImage: "hand.raised") }
        }
    }
}
