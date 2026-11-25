import XCTest
@testable import Batches

/// Renders each Batches mark and the end card with the site's sample photos, checks their size
/// and that they aren't blank, and writes them to a folder for looking at.
final class SocialBrandingTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private lazy var out: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "branding-renders")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func sample(_ name: String) throws -> CGImage {
        let url = repo.appending(path: "site/img/\(name).jpg")
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage, "missing \(url.path)")
    }

    private func save(_ image: CGImage?, _ name: String) throws -> CGImage {
        let image = try XCTUnwrap(image, name)
        try XCTUnwrap(SocialRenderer.jpeg(image, quality: 0.85)).write(to: out.appending(path: "\(name).jpg"))
        return image
    }

    /// Not one flat colour: something was actually drawn.
    private func assertNotBlank(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        let small = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { _ in UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let data = try! XCTUnwrap(small.cgImage?.dataProvider?.data as Data?)
        XCTAssertGreaterThan(Set(data).count, 8, "image looks blank", file: file, line: line)
    }

    private let caption = SocialCaption(title: "Fog over the bay", date: ISO8601DateFormatter().date(from: "2026-10-10T18:00:00Z"), index: 3, total: 12)

    func testEveryMarkRendersAtEveryFormat() throws {
        let photos = ["portrait": try sample("print-dawn"), "landscape": try sample("print-sunset")]
        for branding in SocialBranding.allCases {
            for format in SocialFormat.allCases {
                for (shape, photo) in photos {
                    let image = try save(SocialRenderer.shared.render(photo, format: format, fill: .blur, background: UIColor.white.cgColor,
                                                                      branding: branding, caption: caption),
                                         "\(branding.rawValue)-\(format.rawValue)-\(shape)")
                    XCTAssertEqual(image.width, Int(format.size.width))
                    XCTAssertEqual(image.height, Int(format.size.height))
                    assertNotBlank(image)
                }
            }
        }
        print("SocialBrandingTests: renders in \(out.path)")
    }

    func testPreviewScaleMatchesFullScaleLayout() throws {
        let photo = try sample("print-forest")
        let small = try XCTUnwrap(SocialRenderer.shared.render(photo, format: .vertical, fill: .blur, background: UIColor.white.cgColor,
                                                               scale: 1.0 / 3, branding: .print, caption: caption))
        XCTAssertEqual(small.width, 360)
        XCTAssertEqual(small.height, 640)
    }

    func testEndCardRendersWithOneToThreePrints() throws {
        let prints = [try sample("print-dawn"), try sample("print-forest"), try sample("print-sunset")]
        for format in SocialFormat.allCases {
            for count in 1...3 {
                let card = try save(SocialRenderer.shared.endCard(prints: Array(prints.prefix(count)), caption: caption, format: format),
                                    "endcard-\(format.rawValue)-\(count)")
                XCTAssertEqual(card.width, Int(format.size.width))
                assertNotBlank(card)
            }
        }
    }

    func testBrandMarkIsInTheApp() {
        XCTAssertNotNil(Brand.mark, "BrandMark image set missing from the asset catalog")
    }

    func testDateLines() {
        XCTAssertEqual(BrandDrawing.dateLine(caption, total: true).hasSuffix("3 of 12"), true)
        XCTAssertEqual(BrandDrawing.dateLine(caption, total: false).hasSuffix("12 photos"), true)
        XCTAssertEqual(BrandDrawing.dateLine(SocialCaption(title: "x"), total: true), "")
    }
}
