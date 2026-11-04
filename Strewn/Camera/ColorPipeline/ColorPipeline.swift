import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Which version of the color math a photo renders with. Stored in every recipe's
/// `DevelopState`. Rule: once a build with version N ships, nothing that version N renders
/// may change (kernels, stock numbers, decoder settings, metering). New math gets N + 1,
/// and old photos keep rendering with N.
enum PipelineVersion {
    static let current = 1
    static let supported: Set<Int> = [1]
}

/// Strewn's color science, used by everything that makes pixels: the camera's live preview,
/// the capture, the editor, export, the shared copies and the Photos extension.
///
///  DNG ─CIRAWFilter (Apple rendering off, decoder pinned)─▶ scene-linear Rec.2020
///      ─camera profile 3×3─▶ ─recipe light/color (global, log domain)─▶
///      ─stock crosstalk 3×3─▶ (optional LUT) ─halation─▶ per-layer H&D curves ─▶ print values
///      ─grain─▶ gamut compress into Display P3 ─▶ 10-bit HEIC
///
/// All math runs in one fixed space (linear Rec.2020, D65) no matter which CIContext renders
/// it, and every automatic decision is frozen into the recipe's `DevelopState`, so the same
/// photo renders the same on any device and any day.
final class ColorPipeline: @unchecked Sendable {
    /// The one space Strewn's color math happens in.
    static let sceneSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    /// What photos are saved and shared in.
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    enum PipelineError: LocalizedError {
        case unreadableRAW, unreadableImage, renderFailed, unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadableRAW: "The RAW file couldn't be decoded."
            case .unreadableImage: "The image file couldn't be read."
            case .renderFailed: "The developed photo couldn't be rendered."
            case .unsupportedVersion(let v): "This photo needs color pipeline version \(v), which this build doesn't have."
            }
        }
    }

    /// White balance as chosen in the camera, before it is frozen.
    enum CaptureWhiteBalance: Sendable {
        case film
        case kelvin(Float, tint: Float)
        case auto
    }

    enum PreviewEncoding: Sendable { case appleLog, display }

    /// Fixed settings of pipeline version 1. Frozen once shipped.
    enum V1 {
        static let luminanceNoiseReduction: Float = 0.2
        static let colorNoiseReduction: Float = 0.5
        static let sharpness: Float = 0.2
        /// Where Strewn's meter puts the centre-weighted log average, in stops from middle grey.
        static let meterTargetStops: Float = -0.25
        static let meterLimit: Float = 4
        /// Metering always decodes at this size in draft mode, so the result never depends on
        /// the size or quality of the render that asks for it.
        static let meterLongSide: CGFloat = 512
        /// Slope of the generic curve undone for already processed images.
        static let processedContrast: Float = 1.0
        static let miredsPerTemperatureUnit: Float = 60
        static let tintPerUnit: Float = 40
        static let fadeLift: Float = 0.12
        static let fadeWhite: Float = 0.04
        static let recipeGrain: Float = 0.08
    }

    let context: CIContext
    private let kernels = Kernels()
    private var lutCache: [String: CubeLUT] = [:]
    private let lock = NSLock()

    init() {
        context = CIContext(options: [
            .workingColorSpace: Self.sceneSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            // Full-size develops run in the background: let the viewfinder and UI animations
            // have the GPU first, and render in tiles rather than holding several 12–48 MP
            // half-float buffers at once. Neither changes a pixel of the result.
            .priorityRequestLow: true,
            .memoryTarget: 512
        ])
    }

    // MARK: Freezing a develop (once per photo)

    /// Decides everything automatic about a RAW capture once, at capture time.
    func freezeDevelop(dng: Data, source: DevelopState.SourceKind, whiteBalance: CaptureWhiteBalance,
                       autoExposure: Bool, exposureCompensation: Float, seed: UInt32) throws -> DevelopState {
        let raw = try makeRAW(dng)
        var state = DevelopState(pipelineVersion: PipelineVersion.current, source: source)
        state.decoderVersion = Self.preferredDecoder(for: raw)?.rawValue
        state.baselineExposure = raw.baselineExposure
        switch whiteBalance {
        case .film: state.whiteBalance = .film
        case .kelvin(let k, let tint): state.whiteBalance = .kelvin(k, tint: tint)
        case .auto:
            // CIRAWFilter starts from the DNG's AsShotNeutral; freeze it as a chromaticity.
            let xy = raw.neutralChromaticity
            state.whiteBalance = .asShot(x: Float(xy.x), y: Float(xy.y))
        }
        let key = DeviceProfile.key(for: raw, format: source)
        state.profileKey = key
        state.profileMatrix = DeviceProfile.matrix(for: key)
        state.grainSeed = seed

        if autoExposure {
            // Apple's auto exposure picked the shutter and ISO; Strewn's own meter decides the
            // brightness, so it doesn't depend on Apple's per-device exposure targets.
            let probe = try decodeRAW(dng, develop: state, look: .neutral, recipe: .identity,
                                      draft: true, maxSide: V1.meterLongSide)
            let measured = meterStops(probe) ?? V1.meterTargetStops
            let correction = max(-V1.meterLimit, min(V1.meterLimit, V1.meterTargetStops - measured))
            state.meteringEV = correction + exposureCompensation
        } else {
            // Manual ISO and shutter: respect the physical exposure, like a film camera.
            state.meteringEV = exposureCompensation
        }
        return state
    }

    /// The develop for a source that has none yet (imported files). Deterministic: the same
    /// file always gets the same state.
    func defaultDevelop(forRAW dng: Data) throws -> DevelopState {
        let raw = try makeRAW(dng)
        let source: DevelopState.SourceKind = raw.isLocalToneMapSupported ? .proRAW : .bayerRAW
        return try freezeDevelop(dng: dng, source: source, whiteBalance: .auto, autoExposure: true,
                                 exposureCompensation: 0, seed: Self.stableSeed(dng))
    }

    func defaultDevelop(forProcessed data: Data) -> DevelopState {
        var state = DevelopState(pipelineVersion: PipelineVersion.current, source: .processed)
        state.grainSeed = Self.stableSeed(data)
        return state
    }

    // MARK: Decode to scene-linear

    /// RAW → scene-linear Rec.2020 with every Apple rendering choice switched off and the
    /// frozen develop applied. `recipe` contributes exposure, temperature and tint.
    func decodeRAW(_ dng: Data, develop: DevelopState, look: FilmLook, recipe: EditRecipe,
                   draft: Bool = false, maxSide: CGFloat? = nil) throws -> CIImage {
        guard PipelineVersion.supported.contains(develop.pipelineVersion) else {
            throw PipelineError.unsupportedVersion(develop.pipelineVersion)
        }
        let raw = try makeRAW(dng)

        // Pin the decoder first: changing it changes which adjustments are supported.
        if let pinned = develop.decoderVersion,
           let match = raw.supportedDecoderVersions.first(where: { $0.rawValue == pinned }) {
            raw.decoderVersion = match
        } else if let fallback = Self.preferredDecoder(for: raw) {
            raw.decoderVersion = fallback       // pinned version gone from this OS; see docs
        }

        // Scene-referred: no global tone curve, no shadow boost, no local tone map (ProRAW's
        // Smart HDR gain map), no local contrast, no gamut squeeze.
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isContrastSupported { raw.contrastAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        raw.isGamutMappingEnabled = false
        raw.extendedDynamicRangeAmount = 1
        // Fixed, version-pinned noise reduction and sharpening, never the per-camera defaults.
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = V1.luminanceNoiseReduction }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = V1.colorNoiseReduction }
        if raw.isSharpnessSupported { raw.sharpnessAmount = V1.sharpness }
        // Lens shading and distortion come from the DNG's own opcodes, so they're per-module
        // calibration, not taste. Keep them on.
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }

        if let baseline = develop.baselineExposure { raw.baselineExposure = baseline }
        raw.exposure = develop.meteringEV + recipe.exposure

        switch develop.whiteBalance {
        case .film:
            raw.neutralTemperature = look.balanceKelvin
            raw.neutralTint = 0
        case .kelvin(let k, let tint):
            raw.neutralTemperature = k
            raw.neutralTint = tint
        case .asShot(let x, let y):
            raw.neutralChromaticity = CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            // Raising the assumed light's temperature warms the picture. Steps are in mireds.
            let mired = 1_000_000 / max(raw.neutralTemperature, 1000) - recipe.temperature * V1.miredsPerTemperatureUnit
            raw.neutralTemperature = 1_000_000 / max(mired, 20)
            raw.neutralTint += recipe.tint * V1.tintPerUnit
        }

        raw.isDraftModeEnabled = draft
        if let maxSide {
            let native = max(raw.nativeSize.width, raw.nativeSize.height)
            raw.scaleFactor = Float(min(1, maxSide / native))
        }
        guard let linear = raw.outputImage else { throw PipelineError.unreadableRAW }
        guard let matrix = develop.profileMatrix, matrix.count == 9 else { return linear }
        return inSceneSpace(linear) { self.multiply($0, by: matrix) }
    }

    /// An already processed image (Apple's HEIF, or an import) → approximately scene-linear.
    /// Apple's tone mapping has been baked in, so this path can't be fully consistent; it
    /// undoes a generic curve so the film stages behave about the same as on RAW.
    func decodeProcessed(_ data: Data, recipe: EditRecipe, maxSide: CGFloat? = nil) throws -> CIImage {
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw PipelineError.unreadableImage
        }
        if let maxSide {
            let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
            lanczos.scale = Float(scale)
            image = lanczos.outputImage ?? image
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            // Maps the scene's neutral to a new target. Check the sign against a grey card on device.
            let t = CIFilter.temperatureAndTint()
            t.inputImage = image
            t.neutral = CIVector(x: 6500, y: 0)
            t.targetNeutral = CIVector(x: CGFloat(6500 - recipe.temperature * 2000), y: CGFloat(-recipe.tint * V1.tintPerUnit))
            image = t.outputImage ?? image
        }
        let gain = exp2(recipe.exposure)
        return inSceneSpace(image) { s in
            let linear = self.kernels.inverseDisplay.apply(extent: s.extent, arguments: [s, V1.processedContrast]) ?? s
            return gain == 1 ? linear : self.multiply(linear, by: [gain, 0, 0, 0, gain, 0, 0, 0, gain])
        }
    }

    // MARK: The film

    /// Scene-linear → finished image (linear, in the context's working space, inside P3).
    /// Spatial effects (halation, grain, vignette) are sized relative to the frame, so a
    /// 1600 px preview and the full-size export look the same at the same viewing size.
    func finish(scene: CIImage, recipe: EditRecipe, look: FilmLook, seed: UInt32, includeGrain: Bool = true) -> CIImage {
        let extent = scene.extent
        let longSide = Float(max(extent.width, extent.height))
        return inSceneSpace(scene) { s in
            let toneA = CIVector(x: CGFloat(recipe.contrast), y: CGFloat(recipe.highlights),
                                 z: CGFloat(recipe.shadows), w: CGFloat(recipe.whites))
            let toneB = CIVector(x: CGFloat(recipe.blacks), y: CGFloat(recipe.saturation),
                                 z: CGFloat(recipe.vibrance), w: CGFloat(recipe.vignette))
            var image = self.kernels.sceneTone.apply(extent: extent, arguments: [s, toneA, toneB, CIVector(cgRect: extent)]) ?? s
            image = self.multiply(image, by: look.crosstalk)

            if let name = look.lutResource, let lut = self.lut(named: name) {
                let encoded = self.kernels.logEncode.apply(extent: extent, arguments: [image]) ?? image
                let cube = lut.filter()
                cube.inputImage = encoded
                image = self.kernels.logDecode.apply(extent: extent, arguments: [cube.outputImage ?? encoded]) ?? image
            }

            var halo = image
            if look.halation > 0 {
                let source = self.kernels.halationSource.apply(extent: extent, arguments: [image, look.halationThreshold]) ?? image
                halo = source.clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(look.halationRadius * longSide))
                    .cropped(to: extent)
            }
            let t = look.halationTint
            let halation = CIVector(x: CGFloat(t.x), y: CGFloat(t.y), z: CGFloat(t.z), w: CGFloat(look.halation))
            let curve = CIVector(x: CGFloat(look.toe), y: CGFloat(look.shoulder),
                                 z: CGFloat(look.blackLift + recipe.fade * V1.fadeLift),
                                 w: CGFloat(look.whitePoint - recipe.fade * V1.fadeWhite))
            let print = self.kernels.film.apply(extent: extent, arguments: [
                image, halo, halation, Self.vector(look.gamma), Self.vector(look.offset), curve
            ]) ?? image

            // Grain clumps are a fixed fraction of the frame. When the render is smaller than
            // the grain (previews), the clumps average out, so the amplitude drops with them.
            let pixelsPerClump = longSide / look.grainSize
            var amount = includeGrain ? look.grain + recipe.grain * V1.recipeGrain : 0
            if pixelsPerClump < 1 { amount *= pixelsPerClump }
            let noise = self.grainField(extent: extent, seed: seed, pixelsPerClump: pixelsPerClump)
            let grain = CIVector(x: CGFloat(amount), y: CGFloat(look.grainChroma), z: 0, w: 0)
            return self.kernels.output.apply(extent: extent, arguments: [print, noise, grain]) ?? print
        }
    }

    // MARK: Live preview

    /// A video frame → approximately scene-linear. For Apple Log, pass a CIImage made with
    /// `.colorSpace: NSNull()` so the kernel sees the log code values themselves.
    func previewScene(_ frame: CIImage, encoding: PreviewEncoding) -> CIImage {
        switch encoding {
        case .appleLog:
            let linear = kernels.appleLogDecode.apply(extent: frame.extent, arguments: [frame]) ?? frame
            return linear.matchedToWorkingSpace(from: Self.sceneSpace) ?? linear
        case .display:
            return inSceneSpace(frame) { s in
                self.kernels.inverseDisplay.apply(extent: s.extent, arguments: [s, V1.processedContrast]) ?? s
            }
        }
    }

    /// Applies the preview calibrator's per-channel correction (7 knots of r, g, b stops).
    func correctPreview(_ scene: CIImage, knots: [SIMD3<Float>]) -> CIImage {
        guard knots.count == 7, knots.contains(where: { $0 != .zero }) else { return scene }
        return inSceneSpace(scene) { s in
            self.kernels.previewCorrect.apply(extent: s.extent, arguments: [s as Any] + knots.map { Self.vector($0) as Any }) ?? s
        }
    }

    func exposed(_ scene: CIImage, stops: Float) -> CIImage {
        guard stops != 0 else { return scene }
        let g = exp2(stops)
        return inSceneSpace(scene) { self.multiply($0, by: [g, 0, 0, 0, g, 0, 0, 0, g]) }
    }

    // MARK: Metering

    /// Centre-weighted log-average of a scene-linear image, in stops from middle grey.
    func meterStops(_ scene: CIImage) -> Float? {
        let extent = scene.extent
        guard let s = scene.matchedFromWorkingSpace(to: Self.sceneSpace),
              let weighted = kernels.meter.apply(extent: extent, arguments: [s, CIVector(cgRect: extent)]) else { return nil }
        let average = CIFilter.areaAverage()
        average.inputImage = weighted
        average.extent = extent
        guard let out = average.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: out.extent.origin, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: nil)
        guard px[1] > 0 else { return nil }
        return px[0] / px[1]
    }

    /// Reads a small scene-linear thumbnail as Rec.2020 floats, for the preview calibrator.
    func sample(_ scene: CIImage, width: Int = 64) -> [SIMD3<Float>] {
        let extent = scene.extent
        let scale = CGFloat(width) / extent.width
        let height = max(1, Int((extent.height * scale).rounded()))
        let small = scene.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = small.extent.integral.origin
        var px = [Float](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &px, rowBytes: width * 16,
                       bounds: CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: Self.sceneSpace)
        return stride(from: 0, to: px.count, by: 4).map { SIMD3(px[$0], px[$0 + 1], px[$0 + 2]) }
    }

    // MARK: Output

    func heif10(_ image: CIImage) throws -> Data {
        // Let Core Image's own error through; it says why (memory, format, extent).
        try context.heif10Representation(of: image, colorSpace: Self.outputSpace, options: [:])
    }

    func thumbnail(_ image: CIImage, maxSide: CGFloat = 240) -> CGImage? {
        let scale = maxSide / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Self.outputSpace)
    }

    /// Calibration helper: the RAW developed to scene-linear Rec.2020 with no camera profile
    /// and no film, as a 32-bit float TIFF. Shoot a ColorChecker, export this, read the 24
    /// patch values and fit a profile with tools/fit_device_matrix.py.
    func calibrationTIFF(dng: Data, kelvin: Float = 5500) throws -> Data {
        var develop = try defaultDevelop(forRAW: dng)
        develop.whiteBalance = .kelvin(kelvin, tint: 0)
        develop.profileMatrix = nil
        let scene = try decodeRAW(dng, develop: develop, look: .neutral, recipe: .identity)
        guard let tiff = context.tiffRepresentation(of: scene, format: .RGBAf, colorSpace: Self.sceneSpace) else {
            throw PipelineError.renderFailed
        }
        return tiff
    }

    /// Identifies everything that decides a render's pixels besides the source and recipe,
    /// for the shared copies' render hash (docs/storage-plan.md).
    static func fingerprint(_ develop: DevelopState) -> String {
        "strewn-color/v\(develop.pipelineVersion)/\(develop.decoderVersion ?? "none")"
    }

    // MARK: Helpers

    /// Newest RAW decoder this OS offers for the file, preferring the variants that read the
    /// DNG's own color and noise metadata. Raw values look like "8" and "8.dng".
    static func preferredDecoder(for raw: CIRAWFilter) -> CIRAWDecoderVersion? {
        func rank(_ v: CIRAWDecoderVersion) -> (Int, Int) {
            let number = Int(v.rawValue.prefix { $0.isNumber }) ?? -1
            return (number, v.rawValue.lowercased().contains("dng") ? 1 : 0)
        }
        return raw.supportedDecoderVersions
            .filter { rank($0).0 >= 0 }
            .max { rank($0) < rank($1) }
    }

    /// FNV-1a over the size and the first and last 64 KB. Stable across launches and devices,
    /// unlike Swift's Hasher.
    static func stableSeed(_ data: Data) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        func mix(_ byte: UInt8) { h = (h ^ UInt32(byte)) &* 16_777_619 }
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { $0.forEach(mix) }
        data.prefix(65_536).forEach(mix)
        data.suffix(65_536).forEach(mix)
        return h
    }

    private func makeRAW(_ dng: Data) throws -> CIRAWFilter {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else {
            throw PipelineError.unreadableRAW
        }
        return raw
    }

    /// Runs `body` on the image's values expressed in linear Rec.2020, whatever the
    /// rendering context's working space is.
    private func inSceneSpace(_ image: CIImage, _ body: (CIImage) -> CIImage) -> CIImage {
        guard let s = image.matchedFromWorkingSpace(to: Self.sceneSpace) else { return image }
        let out = body(s)
        return out.matchedToWorkingSpace(from: Self.sceneSpace) ?? out
    }

    /// Row-major 3×3 matrix multiply on the image's raw values.
    private func multiply(_ image: CIImage, by m: [Float]) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: 0)
        f.gVector = CIVector(x: CGFloat(m[3]), y: CGFloat(m[4]), z: CGFloat(m[5]), w: 0)
        f.bVector = CIVector(x: CGFloat(m[6]), y: CGFloat(m[7]), z: CGFloat(m[8]), w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// Uniform noise around 0.5 with clumps `pixelsPerClump` wide, offset by the photo's seed.
    /// CIRandomGenerator is a fixed pattern, so the same seed gives the same grain every time.
    private func grainField(extent: CGRect, seed: UInt32, pixelsPerClump: Float) -> CIImage {
        guard var noise = CIFilter.randomGenerator().outputImage else { return CIImage(color: .gray).cropped(to: extent) }
        noise = noise.transformed(by: CGAffineTransform(translationX: -CGFloat(seed & 0xFFF), y: -CGFloat((seed >> 12) & 0xFFF)))
        let scale = CGFloat(pixelsPerClump)
        if scale > 1 {
            noise = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .applyingGaussianBlur(sigma: Double(0.35 * scale))
        }
        return noise.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }

    private static func vector(_ v: SIMD3<Float>) -> CIVector {
        CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z))
    }

    private func lut(named name: String) -> CubeLUT? {
        lock.lock(); defer { lock.unlock() }
        if let cached = lutCache[name] { return cached }
        let loaded = CubeLUT(named: name)
        if let loaded { lutCache[name] = loaded }
        return loaded
    }

    private struct Kernels {
        let sceneTone = Kernels.load("strewnSceneTone_v1")
        let halationSource = Kernels.load("strewnHalationSource_v1")
        let film = Kernels.load("strewnFilm_v1")
        let output = Kernels.load("strewnOutput_v1")
        let appleLogDecode = Kernels.load("strewnAppleLogDecode_v1")
        let inverseDisplay = Kernels.load("strewnInverseDisplay_v1")
        let previewCorrect = Kernels.load("strewnPreviewCorrect_v1")
        let meter = Kernels.load("strewnMeter_v1")
        let logEncode = Kernels.load("strewnLogEncode_v1")
        let logDecode = Kernels.load("strewnLogDecode_v1")

        static func load(_ name: String) -> CIColorKernel {
            // Xcode compiles *.ci.metal into default.metallib when the -fcikernel flags are set.
            // Bundle(for:) so the Photos extension finds its own copy.
            guard let url = Bundle(for: ColorPipeline.self).url(forResource: "default", withExtension: "metallib"),
                  let data = try? Data(contentsOf: url),
                  let kernel = try? CIColorKernel(functionName: name, fromMetalLibraryData: data)
            else { fatalError("Missing Core Image kernel \(name). Check the -fcikernel build flags.") }
            return kernel
        }
    }
}
