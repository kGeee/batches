import AVFoundation
import UIKit
import XCTest
@testable import Batches

final class SocialExportTests: XCTestCase {
    /// A solid post-sized slide with a stripe, so frames differ.
    private func slide(_ index: Int, size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let hue = CGFloat(index % 8) / 8
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.1))
        }.cgImage!
    }

    private func writeVideo(slides count: Int, options: SlideshowWriter.Options, loadDelay: Duration = .zero) async throws -> (URL, TimeInterval) {
        let size = SocialFormat.vertical.size
        let url = FileManager.default.temporaryDirectory.appending(path: "slideshow-\(UUID().uuidString).mp4")
        let images = (0..<count).map { slide($0, size: size) }
        let start = Date()
        try await SlideshowWriter.write(count: count, size: size, options: options, to: url,
                                        slide: { index in
                                            if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
                                            return images[index]
                                        },
                                        progress: { _ in })
        return (url, Date().timeIntervalSince(start))
    }

    func testVideoHasExactLengthAndFrameCount() async throws {
        let options = SlideshowWriter.Options(secondsPerPhoto: 1.5, slowZoom: true)
        let (url, elapsed) = try await writeVideo(slides: 4, options: options)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 6, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
        print("SocialExportTests: 4 slides x 1.5 s rendered in \(String(format: "%.2f", elapsed)) s")
    }

    /// 10 photos at 2.5 s (750 frames at 1080x1920), the common case. Prints the time to compare runs.
    func testRenderSpeedTenSlides() async throws {
        let (url, elapsed) = try await writeVideo(slides: 10, options: .init(secondsPerPhoto: 2.5, slowZoom: true))
        defer { try? FileManager.default.removeItem(at: url) }
        print("SocialExportTests: 10 slides x 2.5 s rendered in \(String(format: "%.2f", elapsed)) s")
    }

    /// Slow photo loads (as from the network) should overlap with encoding, not add up.
    func testSlowLoadsOverlapEncoding() async throws {
        let (url, elapsed) = try await writeVideo(slides: 6, options: .init(secondsPerPhoto: 1.5, slowZoom: false), loadDelay: .milliseconds(400))
        defer { try? FileManager.default.removeItem(at: url) }
        print("SocialExportTests: 6 slides with 400 ms loads rendered in \(String(format: "%.2f", elapsed)) s")
    }

    func testCancelStopsAndRemovesFile() async throws {
        let size = SocialFormat.vertical.size
        let url = FileManager.default.temporaryDirectory.appending(path: "cancel-\(UUID().uuidString).mp4")
        let image = slide(0, size: size)
        let task = Task {
            try await SlideshowWriter.write(count: 30, size: size, options: .init(secondsPerPhoto: 4), to: url,
                                            slide: { _ in image }, progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTimingMatchesPreview() {
        let timing = SlideshowWriter.Timing(slides: 3, options: .init(secondsPerPhoto: 2.5, fadeSeconds: 0.4))
        XCTAssertEqual(timing.framesPerSlide, 75)
        XCTAssertEqual(timing.fadeFrames, 12)
        XCTAssertEqual(timing.totalFrames, 225)
        XCTAssertEqual(timing.fadeIn(frame: 62, slides: 3), 0)
        XCTAssertGreaterThan(timing.fadeIn(frame: 63, slides: 3), 0)
        XCTAssertEqual(timing.fadeIn(frame: 224, slides: 3), 0, "no fade after the last slide")
    }

    // MARK: GPU composer matches the old Core Graphics drawing

    /// Top half red, bottom half blue, so a flipped frame is caught.
    private func twoTone(_ size: CGSize, top: UIColor = .red, bottom: UIColor = .blue) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            top.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            bottom.setFill(); ctx.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }.cgImage!
    }

    /// RGBA of one pixel, with y measured from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testComposerKeepsOrientation() throws {
        let size = SocialFormat.vertical.size
        let composer = SlideshowWriter.FrameComposer(size: size)
        let slide = try XCTUnwrap(composer.upload(twoTone(size)))
        let frame = try XCTUnwrap(composer.image(current: slide, currentGrow: 0, next: nil, nextGrow: 0, fade: 0))
        let top = pixel(frame, x: 540, y: 100), bottom = pixel(frame, x: 540, y: 1800)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 40)
        XCTAssertGreaterThan(bottom.b, 200); XCTAssertLessThan(bottom.r, 40)
    }

    func testComposerZoomsAboutTheCentre() throws {
        let size = SocialFormat.vertical.size
        let composer = SlideshowWriter.FrameComposer(size: size)
        let slide = try XCTUnwrap(composer.upload(twoTone(size)))
        // At 5% zoom the red/blue line stays at the centre and the frame is still fully covered.
        let frame = try XCTUnwrap(composer.image(current: slide, currentGrow: 0.05, next: nil, nextGrow: 0, fade: 0))
        XCTAssertGreaterThan(pixel(frame, x: 540, y: 955).r, 200)
        XCTAssertGreaterThan(pixel(frame, x: 540, y: 965).b, 200)
        XCTAssertGreaterThan(pixel(frame, x: 0, y: 0).r, 200, "corners stay covered")
    }

    func testComposerCrossFadesByAlpha() throws {
        let size = SocialFormat.square.size
        let composer = SlideshowWriter.FrameComposer(size: size)
        let black = try XCTUnwrap(composer.upload(twoTone(size, top: .black, bottom: .black)))
        let white = try XCTUnwrap(composer.upload(twoTone(size, top: .white, bottom: .white)))
        let half = try XCTUnwrap(composer.image(current: black, currentGrow: 0, next: white, nextGrow: 0, fade: 0.5))
        let mid = pixel(half, x: 540, y: 540)
        XCTAssertEqual(Double(mid.r), 128, accuracy: 6, "blends on sRGB-encoded values, as the Core Graphics drawing did")
        let none = try XCTUnwrap(composer.image(current: black, currentGrow: 0, next: white, nextGrow: 0, fade: 0))
        XCTAssertLessThan(pixel(none, x: 540, y: 540).r, 5)
    }

    // MARK: Transitions

    func testCutHasNoTransitionFrames() {
        let timing = SlideshowWriter.Timing(slides: 3, options: .init(secondsPerPhoto: 2.5, transition: .cut))
        XCTAssertEqual(timing.fadeFrames, 0)
        XCTAssertEqual(timing.totalFrames, 225, "length is the same whatever the transition")
    }

    func testPosesStartAndEndOnTheRightSlide() {
        for transition in SlideTransition.allCases {
            let start = transition.pose(0), end = transition.pose(1)
            XCTAssertEqual(end.incomingShift, 0, accuracy: 0.0001, "\(transition) lands centred")
            XCTAssertEqual(end.incomingScale, 0, accuracy: 0.0001, "\(transition) lands at size")
            XCTAssertEqual(end.incomingOpacity, 1, accuracy: 0.0001, "\(transition) lands opaque")
            if transition == .slide {
                XCTAssertEqual(start.incomingShift, 1, accuracy: 0.0001, "slide starts off the right edge")
                XCTAssertEqual(end.outgoingShift, -1, accuracy: 0.0001, "slide pushes the last photo off the left")
            }
        }
    }

    func testSlideHalfwayShowsBothSlidesSideBySide() throws {
        let size = SocialFormat.square.size
        let composer = SlideshowWriter.FrameComposer(size: size)
        let red = try XCTUnwrap(composer.upload(twoTone(size, top: .red, bottom: .red)))
        let blue = try XCTUnwrap(composer.upload(twoTone(size, top: .blue, bottom: .blue)))
        let half = try XCTUnwrap(composer.image(current: red, currentGrow: 0, next: blue, nextGrow: 0, fade: 0.5, transition: .slide))
        XCTAssertGreaterThan(pixel(half, x: 200, y: 540).r, 200, "outgoing photo on the left")
        XCTAssertGreaterThan(pixel(half, x: 880, y: 540).b, 200, "incoming photo on the right")
    }

    func testEveryTransitionWritesAVideoOfTheSameLength() async throws {
        for transition in SlideTransition.allCases {
            let (url, _) = try await writeVideo(slides: 3, options: .init(secondsPerPhoto: 1.5, slowZoom: true, transition: transition))
            defer { try? FileManager.default.removeItem(at: url) }
            let duration = try await AVURLAsset(url: url).load(.duration)
            XCTAssertEqual(duration.seconds, 4.5, accuracy: 0.001, "\(transition)")
        }
    }
}
