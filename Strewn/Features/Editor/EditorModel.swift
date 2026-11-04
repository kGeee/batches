import CoreImage
import SwiftUI
import UIKit

/// State for one editing session: the recipe, undo history, compare, copy/paste and
/// live preview rendering. Knows nothing about piles or the backend, so the Photos
/// extension can use it too.
@MainActor
@Observable
final class EditorModel {
    enum Tool: String, CaseIterable, Identifiable { case looks = "Looks", light = "Light", color = "Color", effects = "Effects", crop = "Crop"; var id: String { rawValue } }

    struct Adjustment: Identifiable, Hashable {
        let keyPath: WritableKeyPath<EditRecipe, Float>
        let title: String
        let range: ClosedRange<Float>
        var id: String { title }
    }

    static let adjustments: [Tool: [Adjustment]] = [
        .light: [.init(keyPath: \.exposure, title: "Exposure", range: -2...2),
                 .init(keyPath: \.contrast, title: "Contrast", range: -1...1),
                 .init(keyPath: \.highlights, title: "Highlights", range: -1...1),
                 .init(keyPath: \.shadows, title: "Shadows", range: -1...1),
                 .init(keyPath: \.whites, title: "Whites", range: -1...1),
                 .init(keyPath: \.blacks, title: "Blacks", range: -1...1)],
        .color: [.init(keyPath: \.temperature, title: "Temperature", range: -1...1),
                 .init(keyPath: \.tint, title: "Tint", range: -1...1),
                 .init(keyPath: \.vibrance, title: "Vibrance", range: -1...1),
                 .init(keyPath: \.saturation, title: "Saturation", range: -1...1)],
        .effects: [.init(keyPath: \.grain, title: "Grain", range: 0...1),
                   .init(keyPath: \.vignette, title: "Vignette", range: -1...1),
                   .init(keyPath: \.fade, title: "Fade", range: 0...1)]
    ]

    var recipe: EditRecipe { didSet { scheduleRender() } }
    var tool: Tool = .light
    var selected: [Tool: Adjustment] = [:]
    var showingOriginal = false { didSet { scheduleRender() } }
    var isDragging = false
    private(set) var preview: CIImage?
    private(set) var isReady = false
    private(set) var errorMessage: String?

    let sourceURL: URL
    let isRAW: Bool
    private let renderer = EditRenderer()
    private var source: EditRenderer.Source?
    private var history: [EditRecipe]
    private var index = 0
    private var renderTask: Task<Void, Never>?
    private let startingRecipe: EditRecipe

    init(sourceURL: URL, recipe: EditRecipe?) {
        self.sourceURL = sourceURL
        self.isRAW = sourceURL.pathExtension.lowercased() == "dng"
        let start = recipe ?? .identity
        self.recipe = start
        self.startingRecipe = start
        self.history = [start]
        for (tool, list) in Self.adjustments { selected[tool] = list.first }
    }

    var hasChanges: Bool { recipe != startingRecipe }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < history.count - 1 }

    func load() async {
        do {
            source = try await EditRenderer.Source.load(from: sourceURL)
            isReady = true
            scheduleRender()
        } catch {
            errorMessage = "Couldn't open the original: \(error.localizedDescription)"
        }
    }

    // MARK: History

    /// Call when a gesture ends (slider released, chip tapped) so each step is one undo.
    func commit() {
        guard recipe != history[index] else { return }
        history.removeSubrange((index + 1)...)
        history.append(recipe)
        index += 1
    }

    func undo() { guard canUndo else { return }; index -= 1; recipe = history[index] }
    func redo() { guard canRedo else { return }; index += 1; recipe = history[index] }

    func reset(_ adjustment: Adjustment) {
        recipe[keyPath: adjustment.keyPath] = EditRecipe.identity[keyPath: adjustment.keyPath]
        commit()
    }

    func revertToOriginal() { recipe = .identity; commit() }

    // MARK: Copy and paste (system pasteboard, so recipes survive between sessions)

    func copyRecipe() {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: EditRecipe.formatIdentifier)
    }

    static var pastedRecipe: EditRecipe? {
        guard let data = UIPasteboard.general.data(forPasteboardType: EditRecipe.formatIdentifier) else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data)
    }

    func pasteRecipe() {
        guard let pasted = Self.pastedRecipe else { return }
        recipe = recipe.pasting(pasted)
        commit()
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard let source else { return }
        renderTask?.cancel()
        let recipe = recipe, draft = isDragging, original = showingOriginal, renderer = renderer
        renderTask = Task {
            let image = await Task.detached(priority: .userInitiated) {
                try? renderer.render(source, recipe: recipe, draft: draft, maxSide: 1600, original: original)
            }.value
            if !Task.isCancelled { preview = image }
        }
    }

    /// Full-resolution render for saving or sharing.
    func exportHEIF() async throws -> Data {
        guard let source else { throw EditRenderer.RenderError.unreadableSource }
        let recipe = recipe, renderer = renderer
        return try await Task.detached(priority: .userInitiated) { try renderer.exportHEIF(source, recipe: recipe) }.value
    }

    func exportFile() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Batches-\(UUID().uuidString.prefix(8)).heic")
        try await exportHEIF().write(to: url)
        return url
    }
}
