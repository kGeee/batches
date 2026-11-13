import SwiftUI

/// Owner-only: the typeface for a batch's title and captions. Each row previews the batch's own
/// title. Everyone viewing the batch sees the one picked here.
struct BatchFontSheet: View {
    let title: String
    let current: BatchFont?
    let onPick: (BatchFont) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PaperSheet(title: "Font", cancelTitle: nil, confirmTitle: "Done", onConfirm: { dismiss() }) {
            PaperSection(footer: "Titles and captions use this font for everyone who opens the batch.") {
                ForEach(Array(BatchFont.allCases.enumerated()), id: \.element) { index, font in
                    if index > 0 { PaperDivider() }
                    let selected = font == (current ?? .classic)
                    Button { onPick(font) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title).font(font.font(.title3, weight: .semibold)).lineLimit(1)
                                Text(font.title).metaStyle()
                            }
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(font.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
