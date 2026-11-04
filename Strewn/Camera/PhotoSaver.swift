import Photos
import UniformTypeIdentifiers

/// Saves the developed HEIF as the photo and the DNG as its RAW alternate, so Photos
/// shows our look while the original stays editable. Returns the new asset's identifier
/// so later edits can be written back to it as revertible Photos edits.
enum PhotoSaver {
    @discardableResult
    static func save(developed: Data, dng: Data?) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return nil }
        do {
            return try await create(developed: developed, dng: dng)
        } catch where dng != nil {
            // Photos can refuse the HEIC + DNG pair (PHPhotosError 3300, change not supported).
            // The developed photo alone is what people look at; the DNG stays in the app.
            return try await create(developed: developed, dng: nil)
        }
    }

    private static func create(developed: Data, dng: Data?) async throws -> String? {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.heic.identifier
            request.addResource(with: .photo, data: developed, options: options)
            if let dng {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.uniformTypeIdentifier = UTType.rawImage.identifier
                request.addResource(with: .alternatePhoto, data: dng, options: rawOptions)
            }
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        return identifier
    }
}
