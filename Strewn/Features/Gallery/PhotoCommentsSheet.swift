import SwiftUI

/// Comments on one photo. Anyone who can see the photo can read and add them; their author and the
/// batch's owner can remove one; anyone can report one. People on the other side of a block don't
/// see each other's comments (the database leaves them out).
struct PhotoCommentsSheet: View {
    let photo: Photo
    let collection: PhotoCollection
    /// Tells the gallery the new count, so the photo's line stays right.
    var onCountChange: (Int) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [PhotoComment]?
    @State private var draft = ""
    @State private var sending = false
    @State private var failed = false
    @State private var problem: String?
    @State private var reporting: ReportTarget?
    @State private var mentionResults: [User] = []
    @FocusState private var composing: Bool

    private var isOwner: Bool { collection.ownerID == model.me?.id }

    private var activeMentionPrefix: String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            if before.isLetter || before.isNumber || before == "_" || before == "." { return nil }
        }
        let after = String(draft[draft.index(after: atIndex)...])
        guard !after.contains(where: \.isWhitespace), after.count <= 24,
              after.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return nil }
        return after.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: "Comments", cancelTitle: nil, confirmTitle: "Done", onConfirm: { dismiss() })
            List {
                if let comments {
                    ForEach(comments) { comment in
                        row(comment)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) { actions(comment) }
                            .contextMenu { actions(comment) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay { emptyState }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(item: $reporting) { ReportSheet(subject: $0.subject, report: $0.report, owner: $0.owner) }
            .task { await load() }
            .task(id: activeMentionPrefix) {
                guard let prefix = activeMentionPrefix else { mentionResults = []; return }
                if !prefix.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled else { return }
                mentionResults = await model.search(prefix)
            }
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
    }

    private func row(_ comment: PhotoComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let author = comment.author {
                    dismiss()
                    model.linkedUser = author
                }
            } label: {
                AvatarView(user: comment.author, size: 30)
            }
            .buttonStyle(.plain)
            .disabled(comment.author == nil)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author?.displayName ?? "Someone").font(.subheadline.weight(.semibold))
                    Text(comment.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))).metaStyle()
                }
                MentionText(comment.body).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ comment: PhotoComment) -> some View {
        if comment.authorID == model.me?.id || isOwner {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(comment) }
                .tint(.red)
        }
        if comment.authorID != model.me?.id {
            Button("Report", systemImage: "flag") {
                reporting = ReportTarget(subject: "this comment", report: Report(commentID: comment.id, reason: .other),
                                         owner: comment.author)
            }
            .tint(.orange)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if comments == nil && failed {
            ContentUnavailableView {
                Label("Couldn't load comments", systemImage: "wifi.slash")
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if comments == nil {
            ProgressView()
        } else if comments?.isEmpty == true {
            ContentUnavailableView("No comments yet", systemImage: "bubble.left",
                                   description: Text("Say something about this photo."))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if activeMentionPrefix != nil, !mentionResults.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(mentionResults.prefix(8)) { person in
                            Button { insertMention(person) } label: {
                                HStack(spacing: 6) {
                                    AvatarView(user: person, size: 22)
                                    Text("@\(person.handle)").font(.caption.weight(.semibold))
                                }
                                .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
                                .background(Color.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment · @ to mention", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .paperField(focused: composing)
                    .onChange(of: draft) { _, text in
                        if text.count > PhotoComment.maxLength { draft = String(text.prefix(PhotoComment.maxLength)) }
                    }
                Button(action: send) {
                    if sending {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "arrow.up").font(.body.weight(.bold))
                            .foregroundStyle(Color.onAccent)
                            .frame(width: 36, height: 36)
                            .background(Color.strewnAccent, in: Circle())
                    }
                }
                .disabled(trimmed.isEmpty || sending)
                .opacity(trimmed.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Send comment")
            }
            if draft.count > PhotoComment.maxLength - 60 {
                Text("\(PhotoComment.maxLength - draft.count) left").metaStyle()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func insertMention(_ person: User) {
        guard let atIndex = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<atIndex]) + "@\(person.handle) "
        mentionResults = []
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load() async {
        do {
            comments = try await model.comments(on: photo.id)
            failed = false
            onCountChange(comments?.count ?? 0)
        } catch {
            failed = true
        }
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        sending = true
        problem = nil
        Task {
            do {
                let comment = try await model.addComment(text, to: photo.id)
                withAnimation(.snappy) { comments = (comments ?? []) + [comment] }
                draft = ""
                onCountChange(comments?.count ?? 0)
            } catch {
                problem = "Couldn't post the comment. Try again."
            }
            sending = false
        }
    }

    private func delete(_ comment: PhotoComment) {
        let before = comments
        withAnimation(.snappy) { comments?.removeAll { $0.id == comment.id } }
        Task {
            do {
                try await model.deleteComment(comment)
                onCountChange(comments?.count ?? 0)
            } catch {
                comments = before
                problem = "Couldn't delete the comment."
            }
        }
    }
}

/// Owner-only: the short note shown under a batch's title.
struct BatchDescriptionSheet: View {
    let current: String?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var focused: Bool

    init(current: String?, onSave: @escaping (String) -> Void) {
        self.current = current
        self.onSave = onSave
        _draft = State(initialValue: current ?? "")
    }

    var body: some View {
        PaperSheet(title: "Description", onCancel: { dismiss() }, confirmTitle: "Save", onConfirm: { onSave(draft); dismiss() }) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("What's this batch about?", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .paperField(focused: focused)
                    .onChange(of: draft) { _, text in
                        if text.count > PhotoCollection.descriptionLimit { draft = String(text.prefix(PhotoCollection.descriptionLimit)) }
                    }
                Text("\(PhotoCollection.descriptionLimit - draft.count) characters left · everyone who can open the batch sees it")
                    .metaStyle()
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { focused = true }
    }
}

/// Renders @handle mentions as links (`strewn://u/<handle>`) highlighted in the app's accent color.
struct MentionText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let pattern = #/(?:^|(?<=[^a-zA-Z0-9_.]))@([a-zA-Z0-9_.]{3,24})/#
        for match in text.matches(of: pattern) {
            let rawHandle = String(match.output.1).lowercased()
            let cleanHandle = rawHandle.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard User.isValidHandle(cleanHandle),
                  let start = AttributedString.Index(match.range.lowerBound, within: result),
                  let end = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[start..<end].foregroundColor = .strewnAccent
            result[start..<end].link = URL(string: "strewn://u/\(cleanHandle)")
        }
        return result
    }
}

/// A photo's likes, comments and tagged people in the gallery: small, under the print, like a note in pencil.
struct ReactionsLine: View {
    let reactions: PhotoReactions

    var body: some View {
        HStack(spacing: 8) {
            if reactions.likeCount > 0 {
                Label("\(reactions.likeCount)", systemImage: reactions.likedByMe ? "heart.fill" : "heart")
                    .foregroundStyle(reactions.likedByMe ? Color.strewnAccent : .secondary)
            }
            if reactions.commentCount > 0 {
                Label("\(reactions.commentCount)", systemImage: "bubble.left").foregroundStyle(.secondary)
            }
            if !reactions.tags.isEmpty {
                Label("\(reactions.tags.count)", systemImage: "tag").foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .labelStyle(CompactLabel())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reactions.likeCount.counted("like")), \(reactions.commentCount.counted("comment")), \(reactions.tags.count.counted("tagged person", plural: "tagged people"))")
    }

    private struct CompactLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) { configuration.icon; configuration.title }
        }
    }
}
