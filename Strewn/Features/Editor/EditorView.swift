import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The editing workspace. Neutral grey surround so color is judged fairly, the photo
/// always shown whole, and every control writes to the recipe rather than the pixels.
struct EditorView: View {
    enum Mode { case app, photosExtension }

    @State var model: EditorModel
    var mode: Mode = .app
    var pileCount: Int = 0
    var onCancel: () -> Void = {}
    var onDone: (EditRecipe) async -> Void = { _ in }
    var onPasteToPile: ((EditRecipe) async -> Void)?

    @State private var isSaving = false
    @State private var savedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if mode == .app { topBar }
            canvas
            panel
        }
        .background(Color(white: 0.10).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.strewnAccent)
        .task { await model.load() }
        .sensoryFeedback(.selection, trigger: model.tool)
        .sensoryFeedback(.success, trigger: savedCount)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Button("Cancel", action: onCancel)
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
            ShareLink(item: EditedPhotoFile(model: model), preview: SharePreview("Edited photo")) {
                Image(systemName: "square.and.arrow.up")
            }
            Menu {
                Button("Copy edits", systemImage: "doc.on.doc") { model.copyRecipe() }
                Button("Paste edits", systemImage: "doc.on.clipboard") { model.pasteRecipe() }
                    .disabled(EditorModel.pastedRecipe == nil)
                if let onPasteToPile {
                    Button("Paste edits to whole batch (\(pileCount))", systemImage: "square.stack") {
                        Task { await onPasteToPile(model.recipe) }
                    }
                }
                Button("Revert to original", systemImage: "arrow.counterclockwise", role: .destructive) { model.revertToOriginal() }
            } label: { Image(systemName: "ellipsis.circle") }
            Button {
                isSaving = true
                Task { await onDone(model.recipe); savedCount += 1; isSaving = false }
            } label: {
                if isSaving { ProgressView() } else { Text("Done").bold() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .top) {
            MetalImageView(image: model.preview)
                .padding(10)
                .overlay { if model.tool == .crop { CropGuide() } }
                // Press and hold anywhere on the photo to see the original.
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.showingOriginal { model.showingOriginal = true } }
                    .onEnded { _ in model.showingOriginal = false })
            HStack {
                Text(model.isRAW ? "RAW · RE-DEVELOP" : "ORIGINAL KEPT · NON-DESTRUCTIVE")
                Spacer()
                if model.showingOriginal {
                    Text("ORIGINAL").padding(.horizontal, 6).background(.white, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.black)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            if !model.isReady { ProgressView().frame(maxHeight: .infinity) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Tool panel

    private var panel: some View {
        VStack(spacing: 10) {
            switch model.tool {
            case .looks: looksRow
            case .crop: cropRow
            default: adjustmentRow
            }
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorModel.Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
    }

    private var looksRow: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(FilmLook.all) { look in
                        chip(look.name, selected: model.recipe.lookID == look.id) {
                            model.recipe.lookID = look.id
                            model.commit()
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            labeledSlider("Strength", value: $model.recipe.lookStrength, range: 0...1) { "\(Int($0 * 100))" }
        }
    }

    private var adjustmentRow: some View {
        let list = EditorModel.adjustments[model.tool] ?? []
        let current = model.selected[model.tool] ?? list[0]
        return VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(list) { adj in
                        chip(adj.title, selected: adj == current, changed: model.recipe[keyPath: adj.keyPath] != 0) {
                            model.selected[model.tool] = adj
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            labeledSlider(current.title, value: $model.recipe[dynamicMember: current.keyPath], range: current.range,
                          reset: { model.reset(current) }) { value in
                current.keyPath == \.exposure ? String(format: "%+.2f EV", value) : String(format: "%+d", Int((value * 100).rounded()))
            }
        }
    }

    private var cropRow: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(EditRecipe.Aspect.allCases) { aspect in
                        chip(aspect.title, selected: model.recipe.aspect == aspect) {
                            model.recipe.aspect = aspect
                            model.commit()
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            labeledSlider("Straighten", value: $model.recipe.straighten, range: -10...10) { String(format: "%+.1f°", $0) }
        }
    }

    private func chip(_ title: String, selected: Bool, changed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(selected ? Color.white.opacity(0.12) : .clear, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if changed { Circle().fill(.tint).frame(width: 5, height: 5).offset(x: -3, y: 3) }
                }
        }
        .foregroundStyle(selected ? .primary : .secondary)
    }

    private func labeledSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                               reset: (() -> Void)? = nil, format: @escaping (Float) -> String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(format(value.wrappedValue)).font(.caption.monospaced())
                Spacer()
                if let reset { Button("Reset", action: reset).font(.caption) }
            }
            Slider(value: value, in: range) { editing in
                model.isDragging = editing
                if !editing { model.commit() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: value.wrappedValue == 0)
        }
        .padding(.horizontal, 16)
    }
}

/// Rule-of-thirds overlay while cropping.
private struct CropGuide: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: g.size.height))
                    p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

/// Lets ShareLink hand the full-resolution edit to the iOS share sheet, rendered on demand.
struct EditedPhotoFile: Transferable {
    let model: EditorModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .heic) { file in
            SentTransferredFile(try await file.model.exportFile())
        }
    }
}
