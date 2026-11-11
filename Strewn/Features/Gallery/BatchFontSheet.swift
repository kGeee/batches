import SwiftUI

/// Owner-only: the typeface for a batch's title and captions. Each row previews the batch's own
/// title. Everyone viewing the batch sees the one picked here.
struct BatchFontSheet: View {
    let title: String
    let current: BatchFont?
    let onPick: (BatchFont) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(BatchFont.allCases) { font in
                Button {
                    onPick(font)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(font.font(.title2, weight: .semibold)).lineLimit(1)
                            Text(font.title).metaStyle()
                        }
                        Spacer()
                        if font == (current ?? .classic) {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(DeskMatBackground())
            .navigationTitle("Font")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.strewnAccent)
    }
}
