import UIKit
import XCTest
@testable import Batches

/// Answers every request from a per-test handler, so GooglePhotos can be driven without Google.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue; _requests = [] } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class GooglePhotosTests: XCTestCase {
    private var google: GooglePhotos!
    private var tempDir: URL!

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        google = GooglePhotos.shared
        google.urlSession = URLSession(configuration: config)
        tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        StubURLProtocol.handler = nil
        google.urlSession = .shared
        google.clearSession()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Fixtures

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func jpeg(width: Int = 40, height: Int = 30) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func decodeItems(_ object: Any) throws -> [GooglePhotos.PickedItem] {
        struct Page: Decodable { let mediaItems: [GooglePhotos.PickedItem] }
        return try JSONDecoder().decode(Page.self, from: json(["mediaItems": object])).mediaItems
    }

    private func item(_ id: String, metadata: [String: Any]? = nil, createTime: String? = "2026-09-12T16:30:00.123Z") -> [String: Any] {
        var file: [String: Any] = ["baseUrl": "https://lh3.googleusercontent.com/pw/\(id)", "mimeType": "image/jpeg", "filename": "\(id).jpg"]
        if let metadata { file["mediaFileMetadata"] = metadata }
        var item: [String: Any] = ["id": id, "type": "PHOTO", "mediaFile": file]
        if let createTime { item["createTime"] = createTime }
        return item
    }

    // MARK: Decoding

    /// The regression fixed in 3dc4e0c: Google sends int64 width/height as strings.
    func testDecodesNumericFieldsSentAsStrings() throws {
        let items = try decodeItems([item("a", metadata: [
            "width": "4032", "height": "3024", "cameraMake": "Apple",
            "photoMetadata": ["focalLength": "6.86", "apertureFNumber": "1.78", "isoEquivalent": "50", "exposureTime": "0.008333s"],
        ])])
        let meta = try XCTUnwrap(items.first?.mediaFile.mediaFileMetadata)
        XCTAssertEqual(meta.width, 4032)
        XCTAssertEqual(meta.height, 3024)
        XCTAssertEqual(meta.photoMetadata?.apertureFNumber, 1.78)
        XCTAssertEqual(meta.photoMetadata?.isoEquivalent, 50)
        XCTAssertEqual(meta.photoMetadata?.focalLength, 6.86)
    }

    func testDecodesNumericFieldsSentAsNumbers() throws {
        let items = try decodeItems([item("a", metadata: [
            "width": 6240, "height": 4160,
            "photoMetadata": ["focalLength": 23.4, "apertureFNumber": 2, "isoEquivalent": 160, "exposureTime": "0.001s"],
        ])])
        let meta = try XCTUnwrap(items.first?.mediaFile.mediaFileMetadata)
        XCTAssertEqual(meta.width, 6240)
        XCTAssertEqual(meta.photoMetadata?.isoEquivalent, 160)
    }

    /// Junk metadata must never fail the whole page, which would lose every pick.
    func testJunkMetadataDoesNotFailThePage() throws {
        let items = try decodeItems([
            item("a", metadata: ["width": "wide", "height": NSNull(), "photoMetadata": "nope"]),
            item("b", metadata: ["photoMetadata": ["isoEquivalent": ["x": 1], "exposureTime": 5]]),
            ["id": "c", "mediaFile": ["baseUrl": "https://x/c", "mimeType": 42, "mediaFileMetadata": []]],
            item("d"),
        ])
        XCTAssertEqual(items.map(\.id), ["a", "b", "c", "d"])
        XCTAssertNil(items[0].mediaFile.mediaFileMetadata?.width)
        XCTAssertNil(items[0].mediaFile.mediaFileMetadata?.photoMetadata)
        XCTAssertNil(items[1].mediaFile.mediaFileMetadata?.photoMetadata?.isoEquivalent)
        XCTAssertNil(items[2].mediaFile.mimeType)
        XCTAssertNil(items[2].type)
    }

    func testMissingBaseUrlFailsTheItem() {
        XCTAssertThrowsError(try decodeItems([["id": "a", "mediaFile": ["mimeType": "image/jpeg"]]]))
    }

    func testDurationParsing() {
        XCTAssertEqual(GooglePhotos.seconds("3.5s"), 3.5)
        XCTAssertEqual(GooglePhotos.seconds("1800s"), 1800)
        XCTAssertNil(GooglePhotos.seconds("0s"))
        XCTAssertNil(GooglePhotos.seconds("3.5"))
        XCTAssertNil(GooglePhotos.seconds(""))
        XCTAssertNil(GooglePhotos.seconds(nil))
    }

    // MARK: Paging

    func testPickedItemsFollowsPagesAndStopsAtTen() async throws {
        var page = 0
        StubURLProtocol.handler = { request in
            page += 1
            let url = request.url!.absoluteString
            XCTAssertTrue(url.hasPrefix("https://photospicker.googleapis.com/v1/mediaItems?sessionId=s1&pageSize=100"))
            if page > 1 { XCTAssertTrue(url.contains("pageToken=p\(page - 1)")) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return (200, [:], self.json(["mediaItems": [self.item("i\(page)")], "nextPageToken": "p\(page)"]))
        }
        let items = try await google.pickedItems(sessionID: "s1", token: "tok")
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(StubURLProtocol.requests.count, 10)
    }

    func testPickedItemsEmptySelection() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data("{}".utf8)) }
        let items = try await google.pickedItems(sessionID: "s1", token: "tok")
        XCTAssertTrue(items.isEmpty)
    }

    func testPickedItemsSurvivesStringDimensions() async throws {
        StubURLProtocol.handler = { _ in
            (200, [:], self.json(["mediaItems": [self.item("a", metadata: ["width": "4032", "height": "3024"])]]))
        }
        let items = try await google.pickedItems(sessionID: "s1", token: "tok")
        XCTAssertEqual(items.first?.mediaFile.mediaFileMetadata?.width, 4032)
    }

    // MARK: Errors

    func testUnauthorizedClearsTokenAndExplains() async {
        StubURLProtocol.handler = { _ in (401, [:], Data()) }
        do {
            let _: GooglePhotos.PickerSession = try await google.request("https://photospicker.googleapis.com/v1/sessions/x", token: "tok")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("expired"), error.localizedDescription)
        }
    }

    func testAPIErrorMessageIsShown() async {
        StubURLProtocol.handler = { _ in (429, [:], self.json(["error": ["code": 429, "message": "Quota exceeded for quota metric"]])) }
        do {
            _ = try await google.send("https://photospicker.googleapis.com/v1/sessions", token: "tok", method: "POST", body: ["a": 1])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Quota exceeded for quota metric")
        }
        let sent = StubURLProtocol.requests.first
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testUnreadableReplyIsAFriendlyError() async {
        StubURLProtocol.handler = { _ in (200, [:], Data("<html>".utf8)) }
        do {
            let _: GooglePhotos.PickerSession = try await google.request("https://photospicker.googleapis.com/v1/sessions/x", token: "tok")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("couldn't read"))
        }
    }

    // MARK: Download

    func testDownloadPrefersFullFrameSizedCopy() async throws {
        let bytes = jpeg()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.absoluteString, "https://lh3.googleusercontent.com/pw/a=w4096-h4096")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return (200, ["Content-Type": "image/jpeg"], bytes)
        }
        let item = try decodeItems([item("a")])[0]
        let file = try await google.download(item, into: tempDir, token: "tok")
        XCTAssertEqual(file.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDownloadFallsBackToOriginalAndPicksExtensionFromContentType() async throws {
        StubURLProtocol.handler = { request in
            request.url!.absoluteString.hasSuffix("=d") ? (200, ["Content-Type": "image/heif"], Data([1, 2, 3])) : (403, [:], Data())
        }
        let item = try decodeItems([item("a")])[0]
        let file = try await google.download(item, into: tempDir, token: "tok")
        XCTAssertEqual(file.pathExtension, "heic")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url!.absoluteString },
                       ["https://lh3.googleusercontent.com/pw/a=w4096-h4096", "https://lh3.googleusercontent.com/pw/a=d"])
    }

    func testDownloadTreatsEmptyBodyAsFailureAndNamesThePhoto() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "image/jpeg"], Data()) }
        let item = try decodeItems([item("IMG_0042")])[0]
        do {
            _ = try await google.download(item, into: tempDir, token: "tok")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("IMG_0042.jpg"), error.localizedDescription)
        }
    }

    func testDownloadNetworkErrorFallsBackThenFails() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let item = try decodeItems([item("a")])[0]
        do {
            _ = try await google.download(item, into: tempDir, token: "tok")
            XCTFail("expected a throw")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testCancelledDownloadThrowsCancellation() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let item = try decodeItems([item("a")])[0]
        do {
            _ = try await google.download(item, into: tempDir, token: "tok")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "a cancel must not retry with =d")
    }

    // MARK: Photo mapping

    /// Google's sized copies drop EXIF, so the picker's metadata fills capture date and camera settings.
    func testMakePhotoFallsBackToPickerMetadata() throws {
        let url = tempDir.appending(path: "a.jpg")
        try jpeg(width: 40, height: 30).write(to: url)
        let item = try decodeItems([item("a", metadata: [
            "width": "4032", "height": "3024",
            "photoMetadata": ["focalLength": "6.86", "apertureFNumber": 1.779, "isoEquivalent": "50", "exposureTime": "0.008s"],
        ])])[0]
        let collection = UUID()
        let photo = google.makePhoto(item, url: url, collectionID: collection, sortIndex: 3)

        XCTAssertEqual(photo.collectionID, collection)
        XCTAssertEqual(photo.sortIndex, 3)
        XCTAssertEqual(photo.imageURL, url)
        // Size comes from the file actually downloaded, not Google's original dimensions.
        XCTAssertEqual(photo.pixelWidth, 40)
        XCTAssertEqual(photo.pixelHeight, 30)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T16:30:00Z")).timeIntervalSince1970 + 0.123
        XCTAssertEqual(try XCTUnwrap(photo.capturedAt).timeIntervalSince1970, expected, accuracy: 0.001)
        XCTAssertEqual(photo.exif?.aperture, 1.78)
        XCTAssertEqual(photo.exif?.shutter, "1/125")
        XCTAssertEqual(photo.exif?.iso, 50)
        XCTAssertEqual(photo.exif?.focalLength, 7)
    }

    func testMakePhotoParsesDatesWithoutFractions() throws {
        let url = tempDir.appending(path: "a.jpg")
        try jpeg().write(to: url)
        let item = try decodeItems([item("a", createTime: "2025-01-02T03:04:05Z")])[0]
        let photo = google.makePhoto(item, url: url, collectionID: UUID(), sortIndex: 0)
        XCTAssertEqual(photo.capturedAt, ISO8601DateFormatter().date(from: "2025-01-02T03:04:05Z"))
        XCTAssertNil(photo.exif, "no picker metadata and no file EXIF means no EXIF")
    }

    func testMakePhotoIgnoresZeroAndMissingSettings() throws {
        let url = tempDir.appending(path: "a.jpg")
        try jpeg().write(to: url)
        let item = try decodeItems([item("a", metadata: ["photoMetadata": ["apertureFNumber": 0, "isoEquivalent": "0"]], createTime: "garbage")])[0]
        let photo = google.makePhoto(item, url: url, collectionID: UUID(), sortIndex: 0)
        XCTAssertNil(photo.exif)
        XCTAssertNil(photo.capturedAt)
    }

    // MARK: Configuration

    func testStageTextCountsDownloads() {
        XCTAssertEqual(GooglePhotos.Stage.downloading(done: 2, total: 5).text, "Importing 2 of 5 from Google Photos…")
    }
}
