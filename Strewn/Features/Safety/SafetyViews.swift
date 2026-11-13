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

    @FocusState private var writing: Bool

    var body: some View {
        PaperSheet(title: "Report", cancelTitle: sent ? nil : "Cancel", onCancel: { dismiss() },
                   confirmTitle: sent ? "Done" : "Send", confirmEnabled: sent || reason != nil, confirmBusy: sending,
                   onConfirm: sent ? finish : send) {
            if sent {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Color.strewnAccent)
                    Text("Thanks for telling us").titleStyle(.title3)
                    Text("We review every report within a day and remove anything that breaks the rules.\(alsoBlock ? " You won't see each other's batches any more." : "")")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            } else {
                PaperSection(title: "What's wrong with \(subject)?") {
                    ForEach(Array(Report.Reason.allCases.enumerated()), id: \.element) { index, option in
                        if index > 0 { PaperDivider() }
                        PaperChoiceRow(title: option.label, selected: reason == option) { reason = option }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PaperLabel("Anything else (optional)").padding(.horizontal, 4)
                    TextField("Details", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($writing)
                        .paperField(focused: writing)
                }
                if let owner, owner.id != model.me?.id, !model.isBlocked(owner) {
                    PaperSection(footer: "Neither of you will see the other's batches, and you'll stop following each other.") {
                        PaperRow { Toggle("Also block @\(owner.handle)", isOn: $alsoBlock).toggleStyle(.paper) }
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            }
        }
    }

    /// The block waits for Done: it can remove the very batch this sheet sits on.
    private func finish() {
        if alsoBlock, let owner { Task { await model.block(owner) } }
        dismiss()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.blocked.isEmpty {
                    Text("You haven't blocked anyone. To block someone, open their desk and tap ⋯.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    PaperSection(footer: "People you block can't see your batches, and you don't see theirs. They aren't told.") {
                        ForEach(Array(model.blocked.enumerated()), id: \.element.id) { index, user in
                            if index > 0 { PaperDivider(inset: 62) }
                            PaperRow {
                                PersonRow(user: user) {
                                    Button("Unblock") { unblocking = user }.buttonStyle(.paper(.secondary, compact: true))
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(DeskMatBackground())
        .paperNavigationTitle("Blocked")
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

    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This deletes, for good:").titleStyle(.title3)
                    bullet("Your profile, @\(handle)")
                    bullet("Every batch you made, for you and everyone you shared it with")
                    bullet("Photos you added to friends' batches, and your likes and comments")
                    bullet("Who you follow, who follows you, and your shares")
                    Text("The photos on this phone stay in your Photos library.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    PaperLabel("Type your handle to confirm").padding(.horizontal, 4)
                    TextField(handle, text: $typed)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($typing)
                        .submitLabel(.done)
                        .paperField(focused: typing)
                }

                Button(action: delete) {
                    HStack(spacing: 8) {
                        if deleting { ProgressView().tint(.white) }
                        Text("Delete my account")
                    }
                }
                .buttonStyle(.paper(.destructive))
                .disabled(!confirmed || deleting)

                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskMatBackground())
        .paperNavigationTitle("Delete account")
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
