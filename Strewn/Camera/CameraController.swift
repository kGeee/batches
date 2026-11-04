import AVFoundation
import CoreImage

/// Owns the capture session. RAW capture is the default so Apple's computational
/// photography (Smart HDR, Deep Fusion, Photographic Styles) never touches the frame:
///
/// - Bayer RAW (default): a single unprocessed sensor readout. Needs a physical camera, not
///   the virtual dual/triple device, so we pick `.builtInWideAngleCamera` (and switch physical
///   devices for .5× and 3×). The most predictable input, so the most consistent color.
/// - Apple ProRAW: Apple's multi-frame merge stored as linear DNG. Cleaner in low light, but
///   Apple doesn't promise it's radiometrically linear, so it's an option, not the default.
/// - HEIF: Apple's processed output, kept as a fallback for devices without RAW.
///
/// The video feed behind the viewfinder is set up to be as unprocessed as the hardware allows
/// (Apple Log where a 4:3 Log format exists, otherwise video HDR off and global rather than
/// local tone mapping), so the live film look matches the developed RAW closely.
final class CameraController: NSObject, @unchecked Sendable {
    enum CaptureFormat: String, CaseIterable, Sendable {
        case bayerRAW, proRAW, heif
        var label: String { switch self { case .bayerRAW: "BAYER RAW"; case .proRAW: "PRORAW"; case .heif: "HEIF" } }
        var developSource: DevelopState.SourceKind {
            switch self { case .bayerRAW: .bayerRAW; case .proRAW: .proRAW; case .heif: .processed }
        }
    }

    struct CapturedPhoto: Sendable {
        let format: CaptureFormat
        let dng: Data?
        let processed: Data?
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// One viewfinder frame. For `.appleLog` the image carries uninterpreted code values.
    struct PreviewFrame: @unchecked Sendable {
        let image: CIImage
        let encoding: ColorPipeline.PreviewEncoding
    }

    /// A physical back camera. Labels are zoom relative to the 1× wide camera.
    struct Lens: Identifiable, Hashable, Sendable {
        let typeName: String
        let label: String
        var id: String { typeName }
        var deviceType: AVCaptureDevice.DeviceType { .init(rawValue: typeName) }
    }

    /// What the auto exposure is doing right now, for the readout.
    struct ExposureReading: Sendable, Equatable {
        let iso: Float
        let shutterSeconds: Double
    }

    enum CameraError: LocalizedError {
        case notAuthorized, noCamera, configurationFailed, captureFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Batches doesn't have access to the camera. You can turn it on in Settings."
            case .noCamera: "This device has no back camera Batches can use."
            case .configurationFailed: "The camera couldn't be set up. Try leaving Shoot and coming back."
            case .captureFailed: "The camera didn't return a photo. Try again."
            }
        }
    }

    let session = AVCaptureSession()
    /// Called on a background queue with each preview frame.
    var onPreviewFrame: (@Sendable (PreviewFrame) -> Void)?
    /// Called on a background queue a few times a second with the live ISO and shutter.
    var onExposureReading: (@Sendable (ExposureReading) -> Void)?
    /// How preview frames are encoded with the current device and format.
    private(set) var previewEncoding: ColorPipeline.PreviewEncoding = .display
    /// Identifies this camera module, for the preview calibration.
    private(set) var moduleKey = "unknown"

    private let sessionQueue = DispatchQueue(label: "strewn.camera.session")
    private let videoQueue = DispatchQueue(label: "strewn.camera.preview", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var captureFormat: CaptureFormat = .bayerRAW
    private var readingCounter = 0   // video queue only

    private var device: AVCaptureDevice? { input?.device }
    /// Tracks how the phone is held, so photos are saved upright. Session queue only.
    private var rotation: AVCaptureDevice.RotationCoordinator?

    // MARK: Setup

    func start(format: CaptureFormat) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.notAuthorized }
        try await onSessionQueue {
            self.captureFormat = format
            if self.input == nil { try self.configure(deviceType: .builtInWideAngleCamera) }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Switch physical lens: .builtInUltraWideCamera (.5×), .builtInWideAngleCamera (1×), .builtInTelephotoCamera.
    func switchLens(to type: AVCaptureDevice.DeviceType) async throws {
        try await onSessionQueue { try self.configure(deviceType: type) }
    }

    /// ProRAW is only switched on while it's the chosen format: with it off, the output lists
    /// Bayer formats only and runs the plainest pipeline.
    func setCaptureFormat(_ format: CaptureFormat) async throws {
        try await onSessionQueue {
            self.captureFormat = format
            let wantsProRAW = format == .proRAW && self.photoOutput.isAppleProRAWSupported
            guard self.photoOutput.isAppleProRAWEnabled != wantsProRAW else { return }
            self.session.beginConfiguration()
            self.photoOutput.isAppleProRAWEnabled = wantsProRAW
            self.session.commitConfiguration()
        }
    }

    private func configure(deviceType: AVCaptureDevice.DeviceType) throws {
        guard let newDevice = AVCaptureDevice.default(deviceType, for: .video, position: .back) else { throw CameraError.noCamera }
        let newInput = try AVCaptureDeviceInput(device: newDevice)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        // We pick the color space ourselves so the feed doesn't change under us.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else { throw CameraError.configurationFailed }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            // Screen-sized buffers, not the 12–48 MP sensor size: the viewfinder only needs
            // to fill the screen, and full-size frames were most of the preview's lag. Also
            // makes focus and exposure changes settle faster.
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isAppleProRAWEnabled = captureFormat == .proRAW && photoOutput.isAppleProRAWSupported
        if photoOutput.isContentAwareDistortionCorrectionSupported { photoOutput.isContentAwareDistortionCorrectionEnabled = false }

        configurePreviewColor(on: newDevice)

        if let largest = newDevice.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        moduleKey = "\(newDevice.modelID)|\(newDevice.deviceType.rawValue)|\(previewEncoding)"
        rotation = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
    }

    /// Makes the viewfinder feed as close to scene-referred as the device allows.
    private func configurePreviewColor(on device: AVCaptureDevice) {
        if useAppleLogPreview(on: device) {
            previewEncoding = .appleLog
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
            return
        }
        previewEncoding = .display
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let format = device.activeFormat
            if format.supportedColorSpaces.contains(.P3_D65) { device.activeColorSpace = .P3_D65 }
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            // One tone curve for the whole frame instead of Apple's local tone mapping, so the
            // calibrator can learn a single inverse for it.
            if format.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = true }
        } catch { }
    }

    /// Apple Log (iPhone 15 Pro and later) gives a log-encoded, barely processed feed. Only
    /// used if a 4:3 Log format exists that still offers Bayer RAW, since the viewfinder must
    /// show the whole photo frame. Needs checking on device: Log formats may all be 16:9.
    private func useAppleLogPreview(on device: AVCaptureDevice) -> Bool {
        func aspect(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Double(d.width) / Double(max(d.height, 1))
        }
        let candidates = device.formats.filter {
            $0.supportedColorSpaces.contains(.appleLog) && $0.isHighestPhotoQualitySupported && abs(aspect($0) - 4.0 / 3.0) < 0.01
        }
        guard let best = candidates.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }) else { return false }
        guard videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.activeColorSpace = .appleLog
            device.unlockForConfiguration()
        } catch { return false }
        if photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
            return true
        }
        session.sessionPreset = .photo          // Log format lost RAW; back to the photo format
        return false
    }

    // MARK: Capabilities

    var supportedFormats: [CaptureFormat] {
        var formats: [CaptureFormat] = []
        if photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
            formats.append(.bayerRAW)
        }
        if photoOutput.isAppleProRAWSupported { formats.append(.proRAW) }
        formats.append(.heif)
        return formats
    }

    // MARK: Capture

    func capture(format: CaptureFormat, flash: Bool) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let settings = self.makeSettings(for: format)
                // Without this every photo is saved in the sensor's landscape orientation.
                if let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture,
                   let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if self.photoOutput.supportedFlashModes.contains(.on) { settings.flashMode = flash ? .on : .off }
                let processor = PhotoCaptureProcessor(format: format) { [weak self] result in
                    self?.sessionQueue.async { self?.inFlight[settings.uniqueID] = nil }
                    continuation.resume(with: result)
                }
                self.inFlight[settings.uniqueID] = processor
                self.photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    private func makeSettings(for format: CaptureFormat) -> AVCapturePhotoSettings {
        let raws = photoOutput.availableRawPhotoPixelFormatTypes
        switch format {
        case .bayerRAW:
            if let type = raws.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                // RAW only: no processed companion, so no Apple processing runs at all.
                let settings = AVCapturePhotoSettings(rawPixelFormatType: type)
                // Required for Bayer RAW: anything else makes capturePhoto throw (the default,
                // .balanced, crashed every shot).
                settings.photoQualityPrioritization = .speed
                return settings
            }
        case .proRAW:
            if let type = raws.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                let settings = AVCapturePhotoSettings(rawPixelFormatType: type)
                settings.photoQualityPrioritization = .quality
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                return settings
            }
        case .heif:
            break
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.photoQualityPrioritization = .balanced
        return settings
    }

    // MARK: Manual exposure, focus and white balance

    /// Exposure compensation in auto mode. The develop applies the same compensation through
    /// Strewn's meter, so it survives Apple's auto exposure.
    func setExposureBias(_ ev: Float) {
        withDevice { d in d.setExposureTargetBias(max(d.minExposureTargetBias, min(d.maxExposureTargetBias, ev))) }
    }

    /// Manual ISO and/or shutter. Pass nil for either to keep the device's current value.
    func setManualExposure(iso: Float?, shutterSeconds: Double?) {
        withDevice { d in
            let format = d.activeFormat
            let isoValue = iso.map { max(format.minISO, min(format.maxISO, $0)) } ?? AVCaptureDevice.currentISO
            let duration = shutterSeconds.map {
                CMTimeClampToRange(CMTime(seconds: $0, preferredTimescale: 1_000_000),
                                   range: CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration))
            } ?? AVCaptureDevice.currentExposureDuration
            d.setExposureModeCustom(duration: duration, iso: isoValue)
        }
    }

    func setAutoExposure() {
        withDevice { d in if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure } }
    }

    /// Locks the feed's white balance to a color temperature. The RAW develop applies the
    /// same temperature exactly via CIRAWFilter, so preview and photo agree.
    func setWhiteBalance(kelvin: Float, tint: Float = 0) {
        withDevice { d in
            guard d.isWhiteBalanceModeSupported(.locked), d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var gains = d.deviceWhiteBalanceGains(for: .init(temperature: kelvin, tint: tint))
            let maxGain = d.maxWhiteBalanceGain
            gains.redGain = max(1, min(maxGain, gains.redGain))
            gains.greenGain = max(1, min(maxGain, gains.greenGain))
            gains.blueGain = max(1, min(maxGain, gains.blueGain))
            d.setWhiteBalanceModeLocked(with: gains)
        }
    }

    func setAutoWhiteBalance() {
        withDevice { d in
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }

    /// Tap to focus and meter. `point` is in device coordinates (0…1, landscape-right).
    /// `lock` focuses and exposes once, then holds (AE/AF lock); otherwise the camera keeps
    /// refocusing on that spot. Exposure is left alone in manual ISO/shutter.
    func focus(at point: CGPoint, lock: Bool, exposure: Bool) {
        withDevice { d in
            let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(focusMode) {
                d.focusPointOfInterest = point      // the point must be set before the mode
                d.focusMode = focusMode
            }
            let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
            if exposure, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(exposureMode) {
                d.exposurePointOfInterest = point
                d.exposureMode = exposureMode
            }
        }
    }

    /// Back to the default: continuous autofocus and auto exposure on the centre of the frame.
    func resetFocus(exposure: Bool) {
        let centre = CGPoint(x: 0.5, y: 0.5)
        withDevice { d in
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = centre }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if exposure {
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = centre }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
        }
    }

    // MARK: Lenses

    /// The back cameras this phone has, widest first.
    static func availableLenses() -> [Lens] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = Set(AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.map(\.deviceType))
        return types.filter(found.contains).map { type in
            let label = switch type {
            case .builtInUltraWideCamera: ".5×"
            case .builtInTelephotoCamera: telephotoLabel()
            default: "1×"
            }
            return Lens(typeName: type.rawValue, label: label)
        }
    }

    /// The telephoto's zoom relative to the wide camera, read from where the virtual camera
    /// switches lenses (2× on some Pros, 3× or 5× on others).
    private static func telephotoLabel() -> String {
        var factor: Double?
        if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
            let f = triple.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            if f.count >= 2, f[0] > 0 { factor = f[1] / f[0] }
        } else if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            factor = dual.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue
        }
        guard let factor else { return "Tele" }
        return factor.rounded() == factor ? "\(Int(factor))×" : String(format: "%.1f×", factor)
    }

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do { try d.lockForConfiguration(); body(d); d.unlockForConfiguration() } catch { }
        }
    }

    private func onSessionQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sessionQueue.async { c.resume(with: Result { try work() }) }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let encoding = previewEncoding
        // Log frames must reach the decode kernel as raw code values, not color managed.
        let image = encoding == .appleLog
            ? CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: buffer)
        onPreviewFrame?(PreviewFrame(image: image, encoding: encoding))

        readingCounter += 1
        if readingCounter % 10 == 0, let onExposureReading, let d = device {
            onExposureReading(ExposureReading(iso: d.iso, shutterSeconds: d.exposureDuration.seconds))
        }
    }
}

/// Collects the delegate callbacks for one capture.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: CameraController.CaptureFormat
    private let completion: (Result<CameraController.CapturedPhoto, Error>) -> Void
    private var dng: Data?
    private var processed: Data?
    private var size: (Int, Int) = (0, 0)
    private var failure: Error?

    init(format: CameraController.CaptureFormat, completion: @escaping (Result<CameraController.CapturedPhoto, Error>) -> Void) {
        self.format = format
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { failure = error; return }
        let dims = photo.resolvedSettings.photoDimensions
        if photo.isRawPhoto {
            dng = photo.fileDataRepresentation()
            size = (Int(photo.resolvedSettings.rawPhotoDimensions.width), Int(photo.resolvedSettings.rawPhotoDimensions.height))
        } else {
            processed = photo.fileDataRepresentation()
            size = (Int(dims.width), Int(dims.height))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? failure { completion(.failure(error)); return }
        guard dng != nil || processed != nil else { completion(.failure(CameraController.CameraError.captureFailed)); return }
        completion(.success(.init(format: format, dng: dng, processed: processed, pixelWidth: size.0, pixelHeight: size.1)))
    }
}
