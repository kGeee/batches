import AVFoundation
import Metal
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Makes Instagram and TikTok ready copies of your photos: single images, a carousel of up to
/// ten, or a slideshow video. Everything is rendered on this phone from the developed photo and
/// handed to the system share sheet; nothing is uploaded and no metadata (GPS included) goes in,
/// since every output is drawn fresh into a new bitmap.
///
/// The app's rule is full frame, so by default the whole photo sits on a blurred copy of itself
/// or on the batch's background. Cropping to fill the post is there, but only when you pick it.
///
/// Sizes follow the platforms' published specs as of November 2026: Instagram feed 4:5 at
/// 1080 x 1350 (its recommended portrait post) and 1:1 at 1080 x 1080; Stories, Reels and TikTok
/// 9:16 at 1080 x 1920; Instagram carousels take up to 10 images; video as H.264 MP4 at 30 fps.
enum SocialFormat: String, CaseIterable, Identifiable {
    case portrait, square, vertical

    var id: Self { self }

    var size: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        case .vertical: CGSize(width: 1080, height: 1920)
        }
    }

    var title: String {
        switch self {
        case .portrait: "Instagram post"
        case .square: "Square post"
        case .vertical: "Story, Reel or TikTok"
        }
    }

    var detail: String {
        switch self {
        case .portrait: "4:5, the tallest a feed post goes"
        case .square: "1:1"
        case .vertical: "9:16, full screen"
        }
    }

    var ratioLabel: String {
        switch self {
        case .portrait: "4:5"
        case .square: "1:1"
        case .vertical: "9:16"
        }
    }
}

/// What goes around a photo that isn't the post's shape.
enum SocialFill: String, CaseIterable, Identifiable {
    /// The whole photo on a soft, blurred copy of itself.
    case blur
    /// The whole photo on the batch's background, with a margin like a print on a wall.
    case background
    /// Fills the post; whatever doesn't fit is cut off.
    case crop

    var id: Self { self }

    var title: String {
        switch self {
        case .blur: "Blur"
        case .background: "Background"
        case .crop: "Crop"
        }
    }
}

enum SocialOutput: String, CaseIterable, Identifiable {
    case images, video
    var id: Self { self }
    var title: String {
        switch self {
        case .images: "Photos"
        case .video: "Video"
        }
    }
}

/// Where a photo lands in a post. Pure geometry, so it can be checked without drawing anything.
enum SocialLayout {
    /// Instagram's carousel limit.
    static let carouselLimit = 10
    /// Keeps a slideshow short enough to post and its render quick.
    static let videoLimit = 30

    static func margin(for canvas: CGSize, fill: SocialFill) -> CGFloat {
        fill == .background ? (canvas.width * 0.06).rounded() : 0
    }

    /// The photo's rectangle in the post, centred. Fit for blur and background, cover for crop.
    static func placement(of image: CGSize, in canvas: CGSize, fill: SocialFill) -> CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let margin = margin(for: canvas, fill: fill)
        let box = CGSize(width: canvas.width - 2 * margin, height: canvas.height - 2 * margin)
        let scale = fill == .crop
            ? max(canvas.width / image.width, canvas.height / image.height)
            : min(box.width / image.width, box.height / image.height)
        let size = CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
        return CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The longest side, in pixels, the photo needs to be decoded at to fill its place sharply.
    static func neededLongEdge(for photo: Photo, format: SocialFormat, fill: SocialFill, scale: CGFloat = 1) -> Int {
        let rect = placement(of: CGSize(width: photo.pixelWidth, height: photo.pixelHeight), in: format.size, fill: fill)
        return Int((max(rect.width, rect.height) * scale).rounded(.up))
    }
}

/// Draws one post at a time.
final class SocialRenderer: @unchecked Sendable {
    static let shared = SocialRenderer()

    private let ci = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// One post: the photo on its fill, at the format's exact size times `scale` (below 1 for a
    /// quick preview that looks the same, just smaller).
    func render(_ photo: CGImage, format: SocialFormat, fill: SocialFill, background: CGColor, scale: CGFloat = 1) -> CGImage? {
        let canvas = CGSize(width: (format.size.width * scale).rounded(), height: (format.size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        context.interpolationQuality = .high
        let whole = CGRect(origin: .zero, size: canvas)
        switch fill {
        case .background:
            context.setFillColor(background)
            context.fill(whole)
        case .blur:
            if let backdrop = blurredBackdrop(photo, canvas: canvas, scale: scale) {
                context.draw(backdrop, in: whole)
            } else {
                context.setFillColor(background)
                context.fill(whole)
            }
        case .crop:
            break
        }
        // The placement is centred, so Core Graphics' bottom-left origin doesn't move it.
        context.draw(photo, in: SocialLayout.placement(of: CGSize(width: photo.width, height: photo.height), in: canvas, fill: fill))
        return context.makeImage()
    }

    /// The photo scaled to cover the post, blurred and dimmed a touch so the sharp copy stands out.
    /// Worked at a quarter size: it's blurred anyway, and drawing it up is free.
    private func blurredBackdrop(_ photo: CGImage, canvas: CGSize, scale: CGFloat) -> CGImage? {
        let small = CGSize(width: (canvas.width / 4).rounded(), height: (canvas.height / 4).rounded())
        let input = CIImage(cgImage: photo)
        let scale = max(small.width / input.extent.width, small.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.minX - (scaled.extent.width - small.width) / 2,
            y: -scaled.extent.minY - (scaled.extent.height - small.height) / 2))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = centred.clampedToExtent()
        blur.radius = Float(14 * scale)
        let tone = CIFilter.colorControls()
        tone.inputImage = blur.outputImage
        tone.brightness = -0.06
        tone.saturation = 1.1
        let frame = CGRect(origin: .zero, size: small)
        guard let output = tone.outputImage?.cropped(to: frame) else { return nil }
        return ci.createCGImage(output, from: frame, format: .BGRA8, colorSpace: colorSpace)
    }

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.92) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Writes posts into an H.264 MP4: each photo holds for a few seconds, cross-fades into the next,
/// and drifts in slowly if asked. No sound: Instagram and TikTok both add music at posting.
/// How one photo gives way to the next in a slideshow.
enum SlideTransition: String, CaseIterable, Identifiable {
    /// The next photo fades in over the last.
    case fade
    /// The next photo pushes the last one off to the left.
    case slide
    /// The next photo settles in from slightly larger as it fades in.
    case zoom
    /// Straight from one to the next.
    case cut

    var id: Self { self }

    var title: String {
        switch self {
        case .fade: "Fade"
        case .slide: "Slide"
        case .zoom: "Zoom"
        case .cut: "Cut"
        }
    }

    /// Eased so moves start and land gently; a fade stays linear, which reads evenly.
    func eased(_ progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return self == .fade ? p : p * p * (3 - 2 * p)
    }

    /// Where the outgoing and incoming slides sit at `progress` through the change, in the
    /// writer and the preview alike: horizontal shift as a fraction of the width (positive is
    /// right), extra scale, and the incoming slide's opacity.
    struct Pose: Equatable {
        var outgoingShift: CGFloat = 0
        var outgoingScale: CGFloat = 0
        var incomingShift: CGFloat = 0
        var incomingScale: CGFloat = 0
        var incomingOpacity: CGFloat = 1
    }

    func pose(_ progress: CGFloat) -> Pose {
        let e = eased(progress)
        switch self {
        case .fade, .cut: return Pose(incomingOpacity: e)
        case .slide: return Pose(outgoingShift: -e, incomingShift: 1 - e)
        case .zoom: return Pose(outgoingScale: 0.06 * e, incomingScale: 0.12 * (1 - e), incomingOpacity: e)
        }
    }
}

enum SlideshowWriter {
    struct Options: Equatable {
        var secondsPerPhoto: Double = 2.5
        var fadeSeconds: Double = 0.4
        var slowZoom = true
        var transition: SlideTransition = .fade
    }

    enum Failure: Error { case setup, missingSlide(Int), write }

    static let fps: Int32 = 30
    /// How far a slide drifts in over its time on screen.
    static let zoomAmount: CGFloat = 0.05

    /// Frame counts for a slideshow, kept apart so the timing can be checked on its own.
    struct Timing: Equatable {
        let framesPerSlide: Int
        let fadeFrames: Int
        let totalFrames: Int

        init(slides: Int, options: Options, fps: Int32 = SlideshowWriter.fps) {
            framesPerSlide = max(1, Int((options.secondsPerPhoto * Double(fps)).rounded()))
            // A slide needs a little longer than a fade to read as movement.
            let seconds = options.transition == .slide ? max(options.fadeSeconds, 0.5) : options.fadeSeconds
            fadeFrames = slides > 1 && options.transition != .cut
                ? min(Int((seconds * Double(fps)).rounded()), framesPerSlide / 2) : 0
            totalFrames = framesPerSlide * max(0, slides)
        }

        /// 0 when a slide first appears, 1 when it's gone: continuous through the fade, so the
        /// drift doesn't jump when the next slide takes over.
        func zoomProgress(slide: Int, frame: Int) -> CGFloat {
            let start = slide * framesPerSlide - fadeFrames
            let length = framesPerSlide + fadeFrames
            return min(1, max(0, CGFloat(frame - start) / CGFloat(length)))
        }

        /// How much of the next slide shows over this frame: 0 outside a fade.
        func fadeIn(frame: Int, slides: Int) -> CGFloat {
            let slide = frame / framesPerSlide
            let local = frame % framesPerSlide
            guard fadeFrames > 0, slide + 1 < slides, local >= framesPerSlide - fadeFrames else { return 0 }
            return CGFloat(local - (framesPerSlide - fadeFrames) + 1) / CGFloat(fadeFrames + 1)
        }
    }

    /// How many slides past the one on screen are loaded ahead, so a slow photo load overlaps
    /// encoding instead of stalling it.
    static let lookahead = 2

    /// `slide` renders one post on demand; only the slides on screen and the few loading ahead
    /// are held in memory. Frames are composed on the GPU with Core Image straight into the
    /// encoder's pixel buffers.
    static func write(count: Int, size: CGSize, options: Options, to url: URL,
                      slide: @escaping (Int) async -> CGImage?,
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.setup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.setup }
        writer.startSession(atSourceTime: .zero)

        let timing = Timing(slides: count, options: options)
        let composer = FrameComposer(size: size)
        // Slides load in their own tasks, `lookahead` ahead of the one being encoded.
        var loading: [Int: Task<CIImage?, Never>] = [:]
        func startLoading(through last: Int) {
            for index in 0...min(last, count - 1) where loading[index] == nil {
                loading[index] = Task { await slide(index).map { composer.upload($0) } ?? nil }
            }
        }
        var held: [Int: CIImage] = [:]
        func slideImage(_ index: Int) async throws -> CIImage {
            if let image = held[index] { return image }
            startLoading(through: index + lookahead)
            guard let image = await loading[index]?.value else { throw Failure.missingSlide(index) }
            loading[index] = nil
            held = held.filter { $0.key >= index - 1 }   // keep only what's still on screen
            held[index] = image
            return image
        }

        do {
            for frame in 0..<timing.totalFrames {
                try Task.checkCancellation()
                let index = frame / timing.framesPerSlide
                let current = try await slideImage(index)
                let fade = timing.fadeIn(frame: frame, slides: count)
                let next = fade > 0 ? try await slideImage(index + 1) : nil

                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let pool = adaptor.pixelBufferPool else { throw Failure.setup }
                var made: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
                    throw Failure.write
                }
                func grow(_ slide: Int) -> CGFloat {
                    options.slowZoom ? zoomAmount * timing.zoomProgress(slide: slide, frame: frame) : 0
                }
                composer.render(current: current, currentGrow: grow(index),
                                next: next, nextGrow: next == nil ? 0 : grow(index + 1), fade: fade,
                                transition: options.transition, into: buffer)

                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw writer.error ?? Failure.write
                }
                if frame % 5 == 0 || frame == timing.totalFrames - 1 {
                    let done = Double(frame + 1) / Double(timing.totalFrames)
                    await progress(done)
                }
            }
        } catch {
            loading.values.forEach { $0.cancel() }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.write }
    }

    /// Composes slideshow frames on the GPU: each slide is uploaded once to an IOSurface-backed
    /// buffer, then every frame is a scale (the slow zoom) and an alpha blend (the cross-fade)
    /// rendered by Core Image into the encoder's buffer. The geometry matches the old Core
    /// Graphics drawing: each post scaled about its centre and cropped to the canvas.
    final class FrameComposer: @unchecked Sendable {
        let size: CGSize
        private let context: CIContext
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        init(size: CGSize) {
            self.size = size
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIContextOption: Any] = [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false]
            if let device = MTLCreateSystemDefaultDevice() {
                context = CIContext(mtlDevice: device, options: options)
            } else {
                context = CIContext(options: options)
            }
        }

        /// The slide in GPU-friendly memory, so frames don't re-upload it from a CGImage each time.
        func upload(_ image: CGImage) -> CIImage? {
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &made) == kCVReturnSuccess, let buffer = made else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: colorSpace, bitmapInfo: SocialRenderer.bitmapInfo) else { return nil }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let ci = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            // Stretch to the canvas if a slide came back at another size, as the old drawing did.
            let sx = size.width / ci.extent.width, sy = size.height / ci.extent.height
            return sx == 1 && sy == 1 ? ci : ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        /// Scaled about the centre by `grow`, then moved across by `shift` widths.
        private func placed(_ image: CIImage, grow: CGFloat, shift: CGFloat = 0) -> CIImage {
            var result = image
            if grow != 0 {
                let scale = 1 + grow
                result = result.transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -size.width / 2, y: -size.height / 2))
            }
            if shift != 0 { result = result.transformed(by: CGAffineTransform(translationX: shift * size.width, y: 0)) }
            return result
        }

        func render(current: CIImage, currentGrow: CGFloat, next: CIImage?, nextGrow: CGFloat, fade: CGFloat,
                    transition: SlideTransition = .fade, into buffer: CVPixelBuffer) {
            let pose = transition.pose(fade)
            let changing = next != nil && fade > 0
            var frame = placed(current, grow: currentGrow + (changing ? pose.outgoingScale : 0),
                               shift: changing ? pose.outgoingShift : 0)
            if let next, changing {
                var top = placed(next, grow: nextGrow + pose.incomingScale, shift: pose.incomingShift)
                if pose.incomingOpacity < 1 {
                    top = top.applyingFilter("CIColorMatrix",
                                             parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: pose.incomingOpacity)])
                }
                frame = top.composited(over: frame)
            }
            let canvas = CGRect(origin: .zero, size: size)
            // Black behind, so a slide never shows stale pixels from a reused buffer.
            let backed = frame.composited(over: CIImage(color: .black).cropped(to: canvas))
            context.render(backed.cropped(to: canvas), to: buffer, bounds: canvas, colorSpace: colorSpace)
        }

        /// One frame as a CGImage, for checking the composer against the old drawing.
        func image(current: CIImage, currentGrow: CGFloat, next: CIImage?, nextGrow: CGFloat, fade: CGFloat,
                   transition: SlideTransition = .fade) -> CGImage? {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
            guard let buffer = made else { return nil }
            render(current: current, currentGrow: currentGrow, next: next, nextGrow: nextGrow, fade: fade,
                   transition: transition, into: buffer)
            return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(origin: .zero, size: size))
        }
    }
}

/// Turns photos into files ready for the share sheet.
enum SocialExport {
    enum Failure: LocalizedError {
        case noPhotos, unreadable, encode

        var errorDescription: String? {
            switch self {
            case .noPhotos: "Pick at least one photo."
            case .unreadable: "A photo couldn't be loaded. Check your connection and try again."
            case .encode: "The post couldn't be made. Try again."
            }
        }
    }

    /// Exports go in one folder that's cleared each time, so old renders don't pile up.
    private static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "SocialExport", directoryHint: .isDirectory) }

    private static func freshFolder() throws -> URL {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The developed photo, decoded just big enough for its place in the post.
    static func source(_ photo: Photo, format: SocialFormat, fill: SocialFill, scale: CGFloat = 1) async -> CGImage? {
        let needed = SocialLayout.neededLongEdge(for: photo, format: format, fill: fill, scale: scale)
        let side = PhotoImageLoader.bucket(for: CGFloat(needed))
        let image = await PhotoImageLoader.shared.image(for: photo.source(for: .l), maxPixelSide: side)
        return image?.cgImage
    }

    static func post(_ photo: Photo, format: SocialFormat, fill: SocialFill, background: CGColor, scale: CGFloat = 1) async -> CGImage? {
        guard let source = await source(photo, format: format, fill: fill, scale: scale) else { return nil }
        return SocialRenderer.shared.render(source, format: format, fill: fill, background: background, scale: scale)
    }

    /// One JPEG per photo, in batch order, named so they sort that way in Files and the share sheet.
    static func images(_ photos: [Photo], name: String, format: SocialFormat, fill: SocialFill, background: CGColor,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> [URL] {
        guard !photos.isEmpty else { throw Failure.noPhotos }
        let folder = try freshFolder()
        var files: [URL] = []
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            guard let post = await post(photo, format: format, fill: fill, background: background) else { throw Failure.unreadable }
            guard let data = SocialRenderer.jpeg(post) else { throw Failure.encode }
            let suffix = photos.count > 1 ? "-\(index + 1)" : ""
            let url = folder.appending(path: "\(fileStem(name))\(suffix).jpg")
            try data.write(to: url)
            files.append(url)
            await progress(Double(index + 1) / Double(photos.count))
        }
        return files
    }

    static func video(_ photos: [Photo], name: String, format: SocialFormat, fill: SocialFill, background: CGColor,
                      options: SlideshowWriter.Options, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard !photos.isEmpty else { throw Failure.noPhotos }
        let url = try freshFolder().appending(path: "\(fileStem(name)).mp4")
        do {
            try await SlideshowWriter.write(count: photos.count, size: format.size, options: options, to: url,
                                            slide: { await post(photos[$0], format: format, fill: fill, background: background) },
                                            progress: progress)
        } catch SlideshowWriter.Failure.missingSlide {
            throw Failure.unreadable
        }
        return url
    }

    /// A batch title as a file name: letters, digits and dashes.
    static func fileStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = title.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let stem = words.joined(separator: "-")
        return stem.isEmpty ? "batch" : String(stem.prefix(40))
    }
}

extension BatchBackground {
    /// The background as a flat colour for a post. Linen is a texture on screen; posts get its
    /// light colour.
    var postColor: CGColor {
        switch self {
        case .desk: UIColor(red: 0.89, green: 0.86, blue: 0.80, alpha: 1).cgColor
        default:
            UIColor(color ?? .white).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        }
    }
}
