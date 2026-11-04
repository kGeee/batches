import CoreImage
import Metal
import QuartzCore
import SwiftUI

/// Draws live frames through the same film pipeline the photo is developed with. The frame is
/// brought to scene-linear (Apple Log decode or an inverse display curve), corrected by the
/// preview calibrator, metered by Strewn's own meter, then run through the exact `finish`
/// stage the RAW goes through. The whole 4:3 sensor frame is shown, letterboxed, never cropped.
///
/// Each camera frame is drawn as it arrives, on the capture's video queue, straight into a
/// CAMetalLayer, so the main thread never waits on the GPU and the viewfinder runs at the
/// camera's own rate. When the GPU falls behind, `nextDrawable` blocks the video queue and the
/// capture output drops the late frames instead of queueing them. Metering reads pixels back
/// from the GPU, so it runs on its own queue and never stalls a frame.
final class PreviewRenderer: @unchecked Sendable {
    let pipeline: ColorPipeline

    /// Settings the UI changes while frames are being drawn.
    private struct Settings {
        var look: FilmLook = .neutral
        var calibrator: PreviewCalibrator?
        var liveMetering = true
        var exposureCompensation: Float = 0
    }

    var look: FilmLook {
        get { lock.withLock { settings.look } }
        set { lock.withLock { settings.look = newValue } }
    }
    var calibrator: PreviewCalibrator? {
        get { lock.withLock { settings.calibrator } }
        set { lock.withLock { settings.calibrator = newValue } }
    }
    /// Off in manual exposure, where brightness should follow the physical settings.
    var liveMetering: Bool {
        get { lock.withLock { settings.liveMetering } }
        set { lock.withLock { settings.liveMetering = newValue } }
    }
    var exposureCompensation: Float {
        get { lock.withLock { settings.exposureCompensation } }
        set { lock.withLock { settings.exposureCompensation = newValue } }
    }

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var context = CIContext(mtlDevice: device, options: [
        .workingColorSpace: ColorPipeline.sceneSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .name: "Strewn viewfinder"
    ])
    private let meterQueue = DispatchQueue(label: "strewn.camera.meter", qos: .utility)
    private let lock = NSLock()
    private var settings = Settings()
    private weak var layer: CAMetalLayer?
    private var meterEV: Float = 0
    private var isMetering = false
    private var sample: [SIMD3<Float>] = []
    private var frameIndex = 0   // video queue only

    init(pipeline: ColorPipeline) {
        self.pipeline = pipeline
    }

    /// A small scene-linear sample of the most recent frame, before calibration and with the
    /// live meter applied. Captured at the shutter press to teach the calibrator.
    var latestSample: [SIMD3<Float>] {
        lock.withLock { sample }
    }

    #if targetEnvironment(simulator)
    private static let pixelFormat = MTLPixelFormat.bgra8Unorm    // the simulator has no extended-range formats
    #else
    private static let pixelFormat = MTLPixelFormat.bgra10_xr
    #endif

    fileprivate func attach(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        lock.withLock { self.layer = layer }
    }

    /// Called on the capture's video queue with each new frame.
    func render(_ frame: CameraController.PreviewFrame) {
        let (layer, settings, meterEV) = lock.withLock { (self.layer, self.settings, self.meterEV) }
        guard let layer, layer.drawableSize.width > 0 else { return }

        frameIndex += 1
        // Meter a few times a second on a tiny copy; smooth so the picture doesn't pump.
        if frameIndex % 6 == 0 { meter(frame, liveMetering: settings.liveMetering) }

        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)

        // Fit to the drawable first, so halation and grain are sized to what's on screen.
        let raw = frame.image
        let fit = min(target.width / raw.extent.width, target.height / raw.extent.height)
        var scene = pipeline.previewScene(raw.transformed(by: CGAffineTransform(scaleX: fit, y: fit)), encoding: frame.encoding)
        scene = scene.transformed(by: CGAffineTransform(translationX: -scene.extent.minX, y: -scene.extent.minY))

        if let knots = settings.calibrator?.knots { scene = pipeline.correctPreview(scene, knots: knots) }
        scene = pipeline.exposed(scene, stops: meterEV + settings.exposureCompensation)
        var image = pipeline.finish(scene: scene, recipe: .identity, look: settings.look, seed: 1)

        let x = (target.width - image.extent.width) / 2
        let y = (target.height - image.extent.height) / 2
        image = image.transformed(by: CGAffineTransform(translationX: x, y: y))

        let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height),
                                              pixelFormat: layer.pixelFormat, commandBuffer: buffer) { drawable.texture }
        destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
        _ = try? context.startTask(toClear: destination)
        _ = try? context.startTask(toRender: image, to: destination)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Runs Strewn's meter and takes the calibrator sample on the meter queue. Skipped while
    /// the previous reading is still in flight.
    private func meter(_ frame: CameraController.PreviewFrame, liveMetering: Bool) {
        let busy = lock.withLock {
            defer { isMetering = true }
            return isMetering
        }
        guard !busy else { return }
        meterQueue.async { [pipeline] in
            let raw = frame.image
            let scale = 96 / raw.extent.width
            var small = pipeline.previewScene(raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), encoding: frame.encoding)
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))

            var ev = self.lock.withLock { self.meterEV }
            if liveMetering, let measured = pipeline.meterStops(small) {
                let wanted = max(-ColorPipeline.V1.meterLimit, min(ColorPipeline.V1.meterLimit, ColorPipeline.V1.meterTargetStops - measured))
                ev += 0.35 * (wanted - ev)
            } else if !liveMetering {
                ev = 0
            }
            let s = pipeline.sample(pipeline.exposed(small, stops: ev))
            self.lock.withLock {
                self.meterEV = ev
                self.sample = s
                self.isMetering = false
            }
        }
    }
}

/// A view backed by a CAMetalLayer the renderer draws into from its own queue.
final class PreviewLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The camera's preview-sized buffers are about 2× the screen in points, so drawing
        // at 3× only upsamples; 2× keeps the full detail at under half the pixels.
        let scale = min(max(traitCollection.displayScale, 1), 2)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

struct CameraPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.backgroundColor = .black
        renderer.attach(view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {}
}
