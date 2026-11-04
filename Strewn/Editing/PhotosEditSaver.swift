import Photos
import UniformTypeIdentifiers

/// Writes an edit into the Photos library the native way: the rendered image plus the
/// recipe as adjustment data. Photos keeps the original, shows "Edited", lets the user
/// Revert, and hands the recipe back to Strewn (app or extension) to keep editing later.
enum PhotosEditSaver {
    enum SaveError: Error { case assetNotFound, noEditingInput }

    static func saveRevertibleEdit(assetID: String, rendered heif: Data, recipe: EditRecipe) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw SaveError.assetNotFound
        }
        let input = try await contentEditingInput(for: asset)
        let output = try makeOutput(for: input, rendered: heif, recipe: recipe)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// Shared with the Photos extension, which receives the input from Photos itself.
    static func makeOutput(for input: PHContentEditingInput, rendered heif: Data, recipe: EditRecipe) throws -> PHContentEditingOutput {
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: EditRecipe.formatIdentifier,
                                                 formatVersion: EditRecipe.formatVersion,
                                                 data: try JSONEncoder().encode(recipe))
        let url = try output.renderedContentURL(for: .heic)
        try heif.write(to: url)
        return output
    }

    static func recipe(from adjustmentData: PHAdjustmentData?) -> EditRecipe? {
        guard let data = adjustmentData, data.formatIdentifier == EditRecipe.formatIdentifier else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data.data)
    }

    private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { $0.formatIdentifier == EditRecipe.formatIdentifier }
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: SaveError.noEditingInput) }
            }
        }
    }
}
