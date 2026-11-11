import SwiftUI

/// Owner-only controls for how a pile is framed. Changes apply for every viewer.
struct FramePickerSheet: View {
    @Binding var frame: FrameStyle
    /// Whether the batch opens as a freehand board instead of one of the frame's layouts.
    @Binding var boardOn: Bool
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
            section("Wall") {
                if frame.kind == .filmStrip {
                    // GalleryView always shows film dark, so there's nothing to pick.
                    Text("Film is always shown on a dark wall.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(height: 36, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        chip("Light", selected: frame.wall == .light) { frame.wall = .light }
                        chip("Dark", selected: frame.wall == .dark) { frame.wall = .dark }
                        chip("Desk", selected: frame.wall == .desk) { frame.wall = .desk }
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
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }.font(.subheadline.weight(.semibold)).padding(.top, 16).padding(.trailing, 20)
        }
        .tint(.strewnAccent)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
            content()
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85).padding(.horizontal, 7).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .strewnAccent : .secondary)
    }
}
