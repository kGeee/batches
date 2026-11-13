import SwiftUI

// The app's own controls, so sheets and settings look like the desk and the batches instead of
// stock iOS forms: linen behind, paper cards on top, serif titles, the amber accent.
//
// Everything here wraps the system control underneath (TextField, Toggle, Button), so keyboard
// focus, return keys, VoiceOver and Dynamic Type keep working; only the drawing changes. Colours
// come from Theme.swift, so light and dark mode follow the system.

// MARK: Sheets

/// The top of a sheet: a serif title with Cancel and a confirm action either side.
struct PaperHeader: View {
    let title: String
    var cancelTitle: String? = "Cancel"
    var onCancel: (() -> Void)? = nil
    var confirmTitle: String? = nil
    var confirmEnabled = true
    var confirmBusy = false
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(.headline, design: .serif, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 90)
                .accessibilityAddTraits(.isHeader)
            HStack {
                if let cancelTitle, let onCancel {
                    Button(cancelTitle, action: onCancel)
                        .font(.body)
                        .frame(minHeight: 44)
                }
                Spacer()
                if confirmBusy {
                    ProgressView().frame(minWidth: 44, minHeight: 44)
                } else if let confirmTitle, let onConfirm {
                    Button(confirmTitle, action: onConfirm)
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(!confirmEnabled)
                        .opacity(confirmEnabled ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .tint(.strewnAccent)
    }
}

/// A whole sheet: header, then scrolling content on the linen.
struct PaperSheet<Content: View>: View {
    let title: String
    var cancelTitle: String? = "Cancel"
    var onCancel: (() -> Void)? = nil
    var confirmTitle: String? = nil
    var confirmEnabled = true
    var confirmBusy = false
    var onConfirm: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PaperHeader(title: title, cancelTitle: cancelTitle, onCancel: onCancel, confirmTitle: confirmTitle,
                        confirmEnabled: confirmEnabled, confirmBusy: confirmBusy, onConfirm: onConfirm)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
    }
}

extension View {
    /// A pushed screen's title in the serif, like the rest of the app. The plain title stays for
    /// the back button and VoiceOver.
    func paperNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.system(.headline, design: .serif, weight: .semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

// MARK: Sections and rows

/// A small caps label above a group, as on the desk and in the account sheet.
struct PaperLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled card of rows, with an optional note underneath.
struct PaperSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { PaperLabel(title).padding(.horizontal, 4) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A hairline between rows in a card, inset past the icon column.
struct PaperDivider: View {
    var inset: CGFloat = 14
    var body: some View { Divider().padding(.leading, inset) }
}

/// One row inside a PaperSection.
struct PaperRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }
}

/// One of several choices, with an amber ring that fills when it's picked.
struct PaperChoiceRow: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol).frame(width: 26).foregroundStyle(Color.strewnAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().strokeBorder(selected ? Color.strewnAccent : Color.secondary.opacity(0.45), lineWidth: 1.5)
                    if selected { Circle().fill(Color.strewnAccent).padding(5) }
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Controls

extension View {
    /// A text field on paper. Apply to a TextField or SecureField; focus and return keys are the
    /// field's own.
    func paperField(focused: Bool = false) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focused ? Color.strewnAccent.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: focused ? 1.5 : 1))
    }
}

/// A switch drawn in the app's colours. VoiceOver still hears a switch.
struct PaperToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Color.strewnAccent : Color.secondary.opacity(0.28))
                    .frame(width: 48, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.paper).padding(3)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == PaperToggleStyle {
    static var paper: PaperToggleStyle { PaperToggleStyle() }
}

/// Full-width buttons: the main action in amber, a quieter one on paper, a destructive one in red.
struct PaperButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PaperButtonLabel(configuration: configuration, kind: kind, compact: compact)
    }

    private struct PaperButtonLabel: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 14 : 18)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 34 : 50)
                .background(background, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .onAccent
            case .secondary: .primary
            case .destructive: .white
            }
        }

        private var background: Color {
            switch kind {
            case .primary: .strewnAccent
            case .secondary: .card
            case .destructive: .red
            }
        }
    }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static func paper(_ kind: PaperButtonStyle.Kind, compact: Bool = false) -> PaperButtonStyle {
        PaperButtonStyle(kind: kind, compact: compact)
    }
}

/// Two or three options side by side, like a segmented control in the app's colours.
struct PaperSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(selected ? Color.onAccent : Color.primary)
                        .background(selected ? Color.strewnAccent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.card, in: Capsule())
    }
}

/// A chip for one option in a row of options, such as a frame or a layout.
struct PaperChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? Color.onAccent : Color.primary)
                .background(selected ? Color.strewnAccent : Color.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(selected ? 0 : 0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: A small text prompt

/// Asks for one line of text, such as a new name. Used instead of a system alert with a field.
struct PaperTextPrompt: View {
    let title: String
    var message: String? = nil
    var placeholder = ""
    var confirmTitle = "Save"
    var limit = 80
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    private let initial: String
    @FocusState private var focused: Bool

    init(title: String, message: String? = nil, placeholder: String = "", initial: String = "",
         confirmTitle: String = "Save", limit: Int = 80, onSave: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.limit = limit
        self.onSave = onSave
        self.initial = initial
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaperHeader(title: title, onCancel: { dismiss() }, confirmTitle: confirmTitle,
                        confirmEnabled: !trimmed.isEmpty, onConfirm: save)
                .padding(.horizontal, -18)
            TextField(placeholder, text: $text)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
                .paperField(focused: focused)
                .onChange(of: text) { _, new in if new.count > limit { text = String(new.prefix(limit)) } }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .onAppear {
            if text.isEmpty { text = initial }
            focused = true
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
