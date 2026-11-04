import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Photos editing extension: lets you open any photo in the Photos app, tap Edit → Strewn,
/// and use the same editor and color pipeline. Edits are saved as revertible Photos edits
/// with the recipe as adjustment data, so they can be reopened and changed later.
final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private var input: PHContentEditingInput?
    private var model: EditorModel?

    // Photos asks whether we understand an earlier edit. If so, it hands us the original
    // plus our recipe; if not, it hands us the current rendered version.
    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == EditRecipe.formatIdentifier
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: UIImage) {
        input = contentEditingInput
        guard let url = contentEditingInput.fullSizeImageURL else { return }
        let recipe = PhotosEditSaver.recipe(from: contentEditingInput.adjustmentData)
        let model = EditorModel(sourceURL: url, recipe: recipe)
        self.model = model

        // Photos supplies Cancel and Done, so the editor hides its own top bar.
        let host = UIHostingController(rootView: EditorView(model: model, mode: .photosExtension))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        guard let input, let model else { completionHandler(nil); return }
        Task { @MainActor in
            do {
                let heif = try await model.exportHEIF()
                let output = try PhotosEditSaver.makeOutput(for: input, rendered: heif, recipe: model.recipe)
                completionHandler(output)
            } catch {
                completionHandler(nil)
            }
        }
    }

    var shouldShowCancelConfirmation: Bool { model?.hasChanges ?? false }

    func cancelContentEditing() {}
}
