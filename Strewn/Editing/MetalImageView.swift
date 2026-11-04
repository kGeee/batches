import CoreImage
import MetalKit
import SwiftUI

/// Shows a CIImage aspect-fit (never cropped) using Metal, redrawing only when the image changes.
struct MetalImageView: UIViewRepresentable {
    let image: CIImage?

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        #if targetEnvironment(simulator)
        view.colorPixelFormat = .bgra8Unorm      // the simulator has no extended-range formats
        #else
        view.colorPixelFormat = .bgra10_xr
        #endif
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        view.setNeedsDisplay()
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()!
        lazy var queue = device.makeCommandQueue()!
        lazy var context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        ])
        var image: CIImage?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image, let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
            let target = view.drawableSize
            let scale = min(target.width / image.extent.width, target.height / image.extent.height)
            var fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            fitted = fitted.transformed(by: CGAffineTransform(
                translationX: (target.width - fitted.extent.width) / 2 - fitted.extent.minX,
                y: (target.height - fitted.extent.height) / 2 - fitted.extent.minY))
            let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height),
                                                  pixelFormat: view.colorPixelFormat, commandBuffer: buffer) { drawable.texture }
            destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            _ = try? context.startTask(toClear: destination)
            _ = try? context.startTask(toRender: fitted, to: destination)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
