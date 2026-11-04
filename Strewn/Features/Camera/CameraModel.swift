import AVFoundation
import CoreImage
import ImageIO
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.kevingeorge.strewn", category: "develop")

/// Each develop step goes to the unified log, and to stdout in debug builds so it shows in
/// `devicectl device process launch --console` and Xcode's console.
private func trace(_ message: String) {
    log.info("\(message, privacy: .public)")
    #if DEBUG
    print("[develop]", message)
    #endif
}

/// UI state for the Shoot tab and the glue between capture, develop and save.
@MainActor
@Observable
final class CameraModel {
    enum Dial: String, CaseIterable { case ev = "EV", iso = "ISO", shutter = "SHUTTER", wb = "WB" }

    /// Film: the stock's own balance, like loading daylight or tungsten film. Auto: the
    /// camera's guess at the moment of capture, frozen. Kelvin: the dial.
    enum WhiteBalanceMode: String, CaseIterable { case film = "Film", auto = "Auto", kelvin = "Kelvin" }

    static let isoStops: [Float] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]
    static let shutterStops: [Double] = [1/4000, 1/2000, 1/1000, 1/500, 1/320, 1/250, 1/125, 1/60, 1/30, 1/15]

    var look: FilmLook = FilmLook.all[1]
    var format: CameraController.CaptureFormat = .bayerRAW
    var availableFormats: [CameraController.CaptureFormat] = [.heif]
    var dial: Dial = .ev
    var exposureBias: Float = 0 {
        didSet { controller.setExposureBias(exposureBias); preview.exposureCompensation = exposureBias }
    }
    var isoIndex: Int? { didSet { applyManualExposure() } }       // nil = auto
    var shutterIndex: Int? { didSet { applyManualExposure() } }   // nil = auto
    var whiteBalanceMode: WhiteBalanceMode = .film { didSet { applyWhiteBalance() } }
    var kelvin: Float = 5500 { didSet { applyWhiteBalance() } }
    var showGrid = true
    var flash = false
    /// The sensor is being read out; the shutter is ready again as soon as this clears.
    private(set) var isCapturing = false
    /// Shots waiting to be developed and saved. Developing runs one at a time behind the
    /// shutter, so you can keep shooting while the last frame develops.
    private(set) var developing = 0
    var lastShot: CGImage?
    var rollCount = 0
    /// Bumped on every shutter press, to blink the viewfinder.
    private(set) var shutterCount = 0
    var errorMessage: String?
    /// The error is missing camera permission, so the alert can offer Settings.
    private(set) var needsCameraAccess = false

    /// Where you tapped to focus, in the viewfinder's own 0…1 coordinates. nil = default
    /// (continuous autofocus on the centre).
    private(set) var focusPoint: CGPoint?
    /// Focus and exposure are held where they landed (long press).
    private(set) var focusLocked = false
    private(set) var lenses: [CameraController.Lens] = []
    private(set) var lens: CameraController.Lens?
    /// What auto exposure has chosen right now, shown dimmed in the readout.
    private(set) var liveExposure: CameraController.ExposureReading?

    var isManualExposure: Bool { isoIndex != nil || shutterIndex != nil }

    /// The white balance the next photo develops with, in Kelvin, for the readout.
    var effectiveKelvin: Float? {
        switch whiteBalanceMode {
        case .film: look.balanceKelvin
        case .kelvin: kelvin
        case .auto: nil
        }
    }

    let controller = CameraController()
    let pipeline: ColorPipeline
    let preview: PreviewRenderer
    /// The editor's renderer, so a capture and a later re-edit are literally the same render.
    private let renderer: EditRenderer
    /// The develop queue: each shot waits for the one before it, so only one full-size RAW
    /// is in memory at a time.
    private var developChain: Task<Void, Never>?

    init() {
        let pipeline = ColorPipeline()
        self.pipeline = pipeline
        renderer = EditRenderer(pipeline: pipeline)
        preview = PreviewRenderer(pipeline: pipeline)
        preview.look = look
        controller.onPreviewFrame = { [preview] frame in preview.render(frame) }
        controller.onExposureReading = { [weak self] reading in
            Task { @MainActor in
                guard let self, self.liveExposure != reading else { return }
                self.liveExposure = reading
            }
        }
    }

    func start() async {
        do {
            try await controller.start(format: format)
            lenses = CameraController.availableLenses()
            lens = lens ?? lenses.first { $0.deviceType == .builtInWideAngleCamera }
            try await afterDeviceChange()
        } catch {
            needsCameraAccess = (error as? CameraController.CameraError) == .notAuthorized
            errorMessage = error.localizedDescription
        }
    }

    func select(lens: CameraController.Lens) {
        guard lens != self.lens, !isCapturing else { return }
        let previous = self.lens
        self.lens = lens
        Task {
            do {
                try await controller.switchLens(to: lens.deviceType)
                try await afterDeviceChange()
            } catch {
                self.lens = previous
                errorMessage = "Couldn't switch to the \(lens.label) camera."
            }
        }
    }

    /// A new physical camera starts from its own defaults, so put every setting back on it.
    private func afterDeviceChange() async throws {
        availableFormats = controller.supportedFormats
        if !availableFormats.contains(format) { format = availableFormats.first ?? .heif }
        try await controller.setCaptureFormat(format)
        preview.calibrator = PreviewCalibrator(moduleKey: controller.moduleKey)
        focusPoint = nil
        focusLocked = false
        applyManualExposure()
        controller.setExposureBias(exposureBias)
        applyWhiteBalance()
    }

    // MARK: Focus

    /// Tap: focus (and meter, in auto exposure) on that spot and keep tracking it.
    /// Long press: focus and expose once, then hold. `point` is 0…1 across the viewfinder.
    func focus(at point: CGPoint, lock: Bool) {
        focusPoint = point
        focusLocked = lock
        // The viewfinder shows the sensor rotated 90° into portrait; the device wants
        // coordinates in the sensor's own landscape orientation.
        controller.focus(at: CGPoint(x: point.y, y: 1 - point.x), lock: lock, exposure: !isManualExposure)
    }

    func resetFocus() {
        focusPoint = nil
        focusLocked = false
        controller.resetFocus(exposure: !isManualExposure)
    }

    // MARK: Dials

    /// Puts the current dial back to its default (auto, or 0 EV).
    func resetDial() {
        switch dial {
        case .ev: exposureBias = 0
        case .iso: isoIndex = nil
        case .shutter: shutterIndex = nil
        case .wb: whiteBalanceMode = .film
        }
    }

    func isDialAtDefault(_ dial: Dial) -> Bool {
        switch dial {
        case .ev: exposureBias == 0
        case .iso: isoIndex == nil
        case .shutter: shutterIndex == nil
        case .wb: whiteBalanceMode == .film
        }
    }

    func stop() { controller.stop() }

    func select(_ look: FilmLook) {
        self.look = look
        preview.look = look
        if whiteBalanceMode == .film { applyWhiteBalance() }
    }

    func cycleFormat() {
        guard let i = availableFormats.firstIndex(of: format) else { return }
        format = availableFormats[(i + 1) % availableFormats.count]
        let format = format
        Task {
            do { try await controller.setCaptureFormat(format) }
            catch { errorMessage = "Couldn't switch to \(format.label)." }
        }
    }

    /// Capture, develop with the same renderer the editor uses, save to Photos and add to
    /// today's pile. The develop decisions are frozen into the photo's recipe, so the saved
    /// shot and any later re-edit are the same render.
    func shoot(into app: AppModel) async {
        guard !isCapturing else { return }
        isCapturing = true
        shutterCount += 1
        let previewSample = preview.latestSample
        let shot: CameraController.CapturedPhoto
        do {
            shot = try await controller.capture(format: format, flash: flash)
        } catch {
            isCapturing = false
            errorMessage = error.localizedDescription
            return
        }
        isCapturing = false

        developing += 1
        let previous = developChain
        // Frozen at the press, so turning a dial while it develops doesn't change this shot.
        let whiteBalance: ColorPipeline.CaptureWhiteBalance = switch whiteBalanceMode {
        case .film: .film
        case .auto: .auto
        case .kelvin: .kelvin(kelvin, tint: 0)
        }
        let settings = ShotSettings(
            whiteBalance: whiteBalance, autoExposure: !isManualExposure, exposureBias: exposureBias, look: look,
            iso: isoIndex.map { Int(Self.isoStops[$0]) })
        developChain = Task {
            await previous?.value
            await develop(shot, previewSample: previewSample, settings: settings, into: app)
            developing -= 1
        }
    }

    private struct ShotSettings: Sendable {
        let whiteBalance: ColorPipeline.CaptureWhiteBalance
        let autoExposure: Bool
        let exposureBias: Float
        let look: FilmLook
        let iso: Int?
    }

    /// Develops with the same renderer the editor uses, saves to Photos and adds to today's pile.
    private func develop(_ shot: CameraController.CapturedPhoto, previewSample: [SIMD3<Float>],
                         settings: ShotSettings, into app: AppModel) async {
        do {
            let photoID = UUID()
            // loadUnaligned: a UUID's bytes have no alignment, and load(as:) on them traps
            // (this crashed every shot right after the shutter).
            let seed = withUnsafeBytes(of: photoID.uuid) { $0.loadUnaligned(as: UInt32.self) }
            let whiteBalance = settings.whiteBalance, autoExposure = settings.autoExposure
            let bias = settings.exposureBias, look = settings.look
            let pipeline = self.pipeline, renderer = self.renderer

            let dir = URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory)
            let imageURL = dir.appending(path: "\(photoID).heic")
            let rawURL = shot.dng.map { _ in dir.appending(path: "\(photoID).dng") }

            // Develop and write files off the main actor, at utility priority, so the camera
            // stays responsive while a full-resolution RAW develops behind it.
            let (recipe, heif, thumb, developedSample, size) = try await Task.detached(priority: .utility) {
                () -> (EditRecipe, Data, CGImage?, [SIMD3<Float>], CGSize) in
                let started = Date()
                trace("start \(shot.format.rawValue) \(shot.pixelWidth)×\(shot.pixelHeight), dng \(shot.dng?.count ?? 0) bytes, processed \(shot.processed?.count ?? 0) bytes")
                var recipe = EditRecipe(lookID: look.id)
                let source: EditRenderer.Source
                if let dng = shot.dng {
                    recipe.develop = try pipeline.freezeDevelop(dng: dng, source: shot.format.developSource, whiteBalance: whiteBalance,
                                                                autoExposure: autoExposure, exposureCompensation: bias, seed: seed)
                    source = .raw(dng)
                } else if let data = shot.processed {
                    recipe.develop = pipeline.defaultDevelop(forProcessed: data)
                    source = .image(data)
                } else {
                    throw CameraController.CameraError.captureFailed
                }
                trace("frozen after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                let image = try renderer.render(source, recipe: recipe)
                let heif = try pipeline.heif10(image)
                trace("rendered after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                // What the RAW really looked like at this moment, for the preview calibrator.
                var sample: [SIMD3<Float>] = []
                if case .raw(let dng) = source, let develop = recipe.develop {
                    let scene = try pipeline.decodeRAW(dng, develop: develop, look: look, recipe: .identity, draft: true, maxSide: 512)
                    sample = pipeline.sample(scene)
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try heif.write(to: imageURL)
                if let rawURL, let dng = shot.dng { try dng.write(to: rawURL) }
                trace("done after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                // The developed image is upright; the sensor's dimensions are always landscape.
                return (recipe, heif, Self.thumbnail(heif), sample, image.extent.size)
            }.value

            if !developedSample.isEmpty { preview.calibrator?.learn(preview: previewSample, developed: developedSample) }
            // The shot is already developed and saved in the app; Photos is a copy. If Photos
            // turns it down, the shot still goes on the roll and you get a note, not a lost photo.
            var assetID: String?
            do {
                assetID = try await PhotoSaver.save(developed: heif, dng: shot.dng)
            } catch {
                trace("Photos save failed: \(String(reflecting: error))")
                errorMessage = "Saved in Batches, but Photos didn't take a copy: \(error.localizedDescription)"
            }
            lastShot = thumb
            rollCount += 1

            let collectionID = app.myCollections.first { $0.title == "Today's roll" }?.id ?? UUID()
            app.addToTodaysRoll(Photo(
                id: photoID, collectionID: collectionID, imageURL: imageURL, rawURL: rawURL,
                pixelWidth: Int(size.width), pixelHeight: Int(size.height), caption: nil, capturedAt: .now,
                exif: .init(iso: settings.iso, lookID: look.id, captureFormat: shot.format.rawValue),
                sortIndex: rollCount, edit: recipe, photosAssetID: assetID))
        } catch {
            trace("FAILED: \(error.localizedDescription) [\(String(reflecting: error))]")
            errorMessage = "Couldn't develop that shot: \(error.localizedDescription)"
        }
    }

    /// The last-shot thumbnail, decoded from the finished HEIF (cheap) rather than by
    /// rendering the whole film pipeline a second time.
    nonisolated private static func thumbnail(_ heif: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(heif as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ] as CFDictionary)
    }

    private func applyManualExposure() {
        preview.liveMetering = !isManualExposure
        if isoIndex == nil && shutterIndex == nil {
            controller.setAutoExposure()
        } else {
            controller.setManualExposure(iso: isoIndex.map { Self.isoStops[$0] },
                                         shutterSeconds: shutterIndex.map { Self.shutterStops[$0] })
        }
    }

    /// The feed's white balance follows the develop's, so the viewfinder matches the photo.
    private func applyWhiteBalance() {
        switch whiteBalanceMode {
        case .film: controller.setWhiteBalance(kelvin: look.balanceKelvin)
        case .kelvin: controller.setWhiteBalance(kelvin: kelvin)
        case .auto: controller.setAutoWhiteBalance()
        }
    }
}
