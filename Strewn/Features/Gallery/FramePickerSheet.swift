import SwiftUI

/// Owner-only controls for how a pile is framed. Changes apply for every viewer.
struct FramePickerSheet: View {
    @Binding var frame: FrameStyle
    /// Whether the batch opens as a freehand board instead of one of the frame's layouts.
    @Binding var boardOn: Bool
    /// What the batch sits on: four presets or the owner's own colour.
    @Binding var background: BatchBackground
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Frame") {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(FrameStyle.Kind.allCases) { kind in
                            chip(kind.title, selected: frame.kind == kind) { frame.kind = kind }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            section("Border  \(Int(frame.borderWidth)) pt") {
                Slider(value: $frame.borderWidth, in: 2...36, step: 1).disabled(frame.kind == .none)
            }
            section("Background") {
                if frame.kind == .filmStrip {
                    // GalleryView always shows film dark, so there's nothing to pick.
                    Text("Film is always shown on a dark wall.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(height: 36, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        ForEach(BatchBackground.presets, id: \.self) { preset in
                            swatch(preset, selected: background == preset) { background = preset }
                        }
                        ColorPicker(selection: Binding(get: { background.color ?? .white },
                                                       set: { background = BatchBackground($0) }),
                                    supportsOpacity: false) {
                            Text("Custom").font(.subheadline.weight(.semibold))
                                .foregroundStyle(background.isCustom ? Color.strewnAccent : .secondary)
                        }
                        .fixedSize()
                        .accessibilityLabel("Custom background colour")
                    }
                }
            }
            section("Layout") {
                if frame.kind == .filmStrip {
                    Text("Film is always shown as a roll.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(height: 36, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        chip("One by one", selected: !boardOn && frame.layout == .single) { boardOn = false; frame.layout = .single }
                        chip("Two columns", selected: !boardOn && frame.layout == .twoColumn) { boardOn = false; frame.layout = .twoColumn }
                        chip("Board", selected: boardOn) { boardOn = true }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DeskMatBackground())
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }.font(.body.weight(.semibold)).padding(.top, 14).padding(.trailing, 20)
        }
        .tint(.strewnAccent)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PaperLabel(title)
            content()
        }
    }

    /// A small square of the background itself, named underneath.
    private func swatch(_ option: BatchBackground, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                option.view
                    .frame(width: 44, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.strewnAccent : Color.secondary.opacity(0.35), lineWidth: selected ? 2.5 : 1))
                Text(option.title).font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.strewnAccent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) background")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        PaperChip(title: title, selected: selected, action: action)
    }

}
