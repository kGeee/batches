import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Turns an untouched original plus an EditRecipe into the edited image. Used for the
/// capture itself, the live editor preview, full-resolution export, pile-wide paste and the
/// Photos extension, so a photo looks the same everywhere it's rendered.
///
/// For Strewn captures the source is the DNG, so exposure and white balance are a true
/// re-develop from sensor data rather than a push on an already-rendered file.
final class EditRenderer: @unchecked Sendable {
    enum Source: Sendable {
        case raw(Data)
        case image(Data)

        static func load(from url: URL) async throws -> Source {
            let (data, _) = try await URLSession.shared.data(from: url)
            let isRAW = ["dng"].contains(url.pathExtension.lowercased())
            return isRAW ? .raw(data) : .image(data)
        }

        var data: Data {
            switch self { case .raw(let d), .image(let d): d }
        }
    }

    enum RenderError: Error { case unreadableSource }

    let pipeline: ColorPipeline
    /// Develop states derived for sources that have none yet, keyed by a stable file hash.
    private var derived: [UInt32: DevelopState] = [:]
    private let lock = NSLock()

    init(pipeline: ColorPipeline = ColorPipeline()) { self.pipeline = pipeline }

    /// - Parameters:
    ///   - draft: faster, lower quality RAW decode for live slider feedback.
    ///   - maxSide: downscale for previews; nil renders full resolution.
    ///   - original: skip the edit (the hold-to-compare view). The develop is kept, so
    ///     "original" means the untouched capture, not Apple's rendering.
    func render(_ source: Source, recipe: EditRecipe, draft: Bool = false, maxSide: CGFloat? = nil, original: Bool = false) throws -> CIImage {
        let develop = try developState(for: source, recipe: recipe)
        let adjust = original ? recipe.reverted() : recipe
        let look = original ? FilmLook.neutral : FilmLook.byID(recipe.lookID).atStrength(recipe.lookStrength)

        let scene: CIImage
        switch source {
        case .raw(let dng):
            scene = try pipeline.decodeRAW(dng, develop: develop, look: look, recipe: adjust, draft: draft, maxSide: maxSide)
        case .image(let data):
            scene = try pipeline.decodeProcessed(data, recipe: adjust, maxSide: maxSide)
        }
        let image = pipeline.finish(scene: scene, recipe: adjust, look: look, seed: develop.grainSeed)
        return original ? image : geometry(image, recipe)
    }

    /// Full-resolution 10-bit HEIF of the edit, with its pixel size (which changes only if the user cropped).
    func export(_ source: Source, recipe: EditRecipe) throws -> (data: Data, size: CGSize) {
        let image = try render(source, recipe: recipe)
        return (try pipeline.heif10(image), image.extent.integral.size)
    }

    func exportHEIF(_ source: Source, recipe: EditRecipe) throws -> Data {
        try export(source, recipe: recipe).data
    }

    /// The recipe with its develop state filled in, for callers that save it. Saving this
    /// instead of a recipe without one pins the photo to today's pipeline version.
    func pinned(_ recipe: EditRecipe, for source: Source) throws -> EditRecipe {
        var result = recipe
        result.develop = try developState(for: source, recipe: recipe)
        return result
    }

    /// For the shared copies' render hash: pipeline and decoder versions behind this render.
    func fingerprint(_ source: Source, recipe: EditRecipe) throws -> String {
        ColorPipeline.fingerprint(try developState(for: source, recipe: recipe))
    }

    // MARK: Stages

    private func developState(for source: Source, recipe: EditRecipe) throws -> DevelopState {
        if let develop = recipe.develop { return develop }
        let key = ColorPipeline.stableSeed(source.data)
        lock.lock()
        if let cached = derived[key] { lock.unlock(); return cached }
        lock.unlock()
        let state: DevelopState
        switch source {
        case .raw(let dng): state = try pipeline.defaultDevelop(forRAW: dng)
        case .image(let data): state = pipeline.defaultDevelop(forProcessed: data)
        }
        lock.lock(); derived[key] = state; lock.unlock()
        return state
    }

    /// Straighten, then crop to the chosen aspect. With .original and 0°, the full frame
    /// passes through untouched.
    private func geometry(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        var image = image
        if r.straighten != 0 {
            let s = CIFilter.straighten()      // rotates and scales so no empty corners show
            s.inputImage = image
            s.angle = r.straighten * .pi / 180
            image = (s.outputImage ?? image).cropped(to: image.extent)
        }
        guard let ratio = r.aspect.ratio else { return image }
        let e = image.extent
        let size = e.width / e.height > ratio
            ? CGSize(width: e.height * ratio, height: e.height)
            : CGSize(width: e.width, height: e.width / ratio)
        let crop = CGRect(x: e.midX - size.width / 2, y: e.midY - size.height / 2, width: size.width, height: size.height)
        return image.cropped(to: crop)
    }
}
