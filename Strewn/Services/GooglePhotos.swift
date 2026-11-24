import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google Photos import with the Google Photos Picker API (photospicker.googleapis.com/v1), the
/// same flow the web uses (web/src/googlePhotos.js):
///   - Only the photos the person chooses in Google's own picker are shared with Batches; the app
///     never asks for read access to their whole library (scope photospicker.mediaitems.readonly).
///   - Sign-in is OAuth 2.0 with PKCE in an ASWebAuthenticationSession against an iOS OAuth client
///     ID (GOOGLE_IOS_CLIENT_ID in Config.local.xcconfig). No Google SDK and no client secret.
///   - The access token lives in memory only and is cleared on sign-out.
///   - Each pick is downloaded full frame (=w4096-h4096, no crop) straight from Google to this
///     phone, then goes through the same upload path as a library pick.
@MainActor
final class GooglePhotos: NSObject {
    static let shared = GooglePhotos()

    enum Failure: LocalizedError {
        case notConfigured
        case cancelled
        case message(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google Photos isn't set up in this build yet."
            case .cancelled: "Google Photos selection was cancelled."
            case .message(let text): text
            }
        }
    }

    enum Stage: Equatable {
        case authorizing
        case creatingSession
        case picking
        case downloading(done: Int, total: Int)

        var text: String {
            switch self {
            case .authorizing: "Connecting to Google Photos…"
            case .creatingSession: "Starting Google Photos…"
            case .picking: "Choose photos in Google Photos, then tap Done."
            case .downloading(let done, let total): "Importing \(done) of \(total) from Google Photos…"
            }
        }
    }

    private static let pickerAPI = "https://photospicker.googleapis.com/v1"
    private static let scope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

    /// "1234-abc.apps.googleusercontent.com", or nil while the build has no client ID.
    static var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GooglePhotosClientID") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasSuffix(".apps.googleusercontent.com"), !value.contains("replace") else { return nil }
        return value
    }

    static var isConfigured: Bool { clientID != nil }

    /// Google's redirect for iOS clients: the client ID reversed, as a custom scheme.
    private static func callbackScheme(for clientID: String) -> String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    private var token: (value: String, expires: Date)?
    /// Every request to Google goes through this; tests swap in a stubbed session.
    var urlSession: URLSession = .shared
    private var webSession: ASWebAuthenticationSession?

    /// Forgets the access token. Called on sign-out.
    func clearSession() {
        token = nil
        closeSheet()
    }

    /// Closes Google's sign-in or picker sheet if one is open; the running pick ends as cancelled.
    func closeSheet() {
        webSession?.cancel()
        webSession = nil
    }

    // MARK: - Whole flow

    /// Signs in if needed, opens Google's picker, waits for Done, downloads the picks and returns
    /// them as local Photos for `collectionID`. Videos are skipped.
    func pick(maxCount: Int = 60, collectionID: UUID, onStage: @escaping (Stage) -> Void) async throws -> [Photo] {
        onStage(.authorizing)
        let accessToken = try await accessToken()

        onStage(.creatingSession)
        let count = max(1, min(60, maxCount))
        let created: PickerSession = try await request("\(Self.pickerAPI)/sessions", token: accessToken, method: "POST",
                                                       body: ["pickingConfig": ["maxItemCount": String(count)]])
        guard let pickerURL = URL(string: created.pickerUri) else {
            throw Failure.message("Google Photos did not return a valid picker session.")
        }
        defer {
            let id = created.id
            Task { try? await self.send("\(Self.pickerAPI)/sessions/\(id)", token: accessToken, method: "DELETE") }
        }

        onStage(.picking)
        try await waitForSelection(session: created, pickerURL: pickerURL, token: accessToken)

        let items = try await pickedItems(sessionID: created.id, token: accessToken)
        let photos = items.filter { item in
            (item.type == nil || item.type == "PHOTO") && (item.mediaFile.mimeType?.hasPrefix("image/") ?? true)
        }.prefix(count)

        let dir = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var result: [Photo] = []
        for (index, item) in photos.enumerated() {
            try Task.checkCancellation()
            onStage(.downloading(done: index, total: photos.count))
            let url = try await download(item, into: dir, token: accessToken)
            result.append(makePhoto(item, url: url, collectionID: collectionID, sortIndex: index))
        }
        onStage(.downloading(done: photos.count, total: photos.count))
        return result
    }

    // MARK: - OAuth (authorization code + PKCE)

    private func accessToken() async throws -> String {
        if let token, token.expires > .now { return token.value }
        guard let clientID = Self.clientID else { throw Failure.notConfigured }
        let scheme = Self.callbackScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        let callback = try await openWebSession(auth.url!, callbackScheme: scheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? Failure.cancelled : Failure.message("Google sign-in failed (\(error)).")
        }
        guard query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else {
            throw Failure.message("Google sign-in did not complete.")
        }

        var exchange = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        exchange.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await urlSession.data(for: exchange)
        struct TokenResponse: Decodable { let access_token: String?; let expires_in: Int?; let error_description: String?; let error: String? }
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let value = decoded?.access_token else {
            throw Failure.message(decoded?.error_description ?? decoded?.error ?? "Google sign-in did not complete.")
        }
        let ttl = max(60, decoded?.expires_in ?? 3600)
        token = (value, Date.now.addingTimeInterval(TimeInterval(ttl - 60)))
        return value
    }

    /// Runs one ASWebAuthenticationSession. It shares cookies with Safari, so the Google account
    /// chosen at sign-in is already signed in when the picker opens in the next session.
    private func openWebSession(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: Failure.message(error?.localizedDescription ?? "Google sign-in could not open."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: Failure.message("Google sign-in could not open."))
            }
        }
    }

    // MARK: - Picker

    struct PickerSession: Decodable {
        let id: String
        let pickerUri: String
        let mediaItemsSet: Bool?
        let pollingConfig: PollingConfig?
        struct PollingConfig: Decodable { let pollInterval: String?; let timeoutIn: String? }
    }

    struct PickedItem: Decodable {
        let id: String
        let createTime: String?
        let type: String?
        let mediaFile: MediaFile
        struct MediaFile: Decodable {
            let baseUrl: String
            let mimeType: String?
            let filename: String?
            let mediaFileMetadata: Metadata?

            enum CodingKeys: String, CodingKey { case baseUrl, mimeType, filename, mediaFileMetadata }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                baseUrl = try c.decode(String.self, forKey: .baseUrl)
                mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType)
                filename = try? c.decodeIfPresent(String.self, forKey: .filename)
                // Metadata is only a fallback for size and EXIF; never fail the import over it.
                mediaFileMetadata = try? c.decodeIfPresent(Metadata.self, forKey: .mediaFileMetadata)
            }
        }
        // Google's JSON sends 64-bit integers as strings ("4032") and others as numbers, so each
        // numeric field takes either form.
        struct Metadata: Decodable {
            let width: Int?
            let height: Int?
            let photoMetadata: PhotoMetadata?

            enum CodingKeys: String, CodingKey { case width, height, photoMetadata }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                width = c.flexibleDouble(.width).map { Int($0) }
                height = c.flexibleDouble(.height).map { Int($0) }
                photoMetadata = try? c.decodeIfPresent(PhotoMetadata.self, forKey: .photoMetadata)
            }
        }
        struct PhotoMetadata: Decodable {
            let focalLength: Double?
            let apertureFNumber: Double?
            let isoEquivalent: Int?
            let exposureTime: String?

            enum CodingKeys: String, CodingKey { case focalLength, apertureFNumber, isoEquivalent, exposureTime }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                focalLength = c.flexibleDouble(.focalLength)
                apertureFNumber = c.flexibleDouble(.apertureFNumber)
                isoEquivalent = c.flexibleDouble(.isoEquivalent).map { Int($0) }
                exposureTime = try? c.decodeIfPresent(String.self, forKey: .exposureTime)
            }
        }
    }

    /// Shows Google's picker in a web session and polls until Google marks the selection done,
    /// then closes the sheet. Closing it without picking is a cancel.
    private func waitForSelection(session: PickerSession, pickerURL: URL, token: String) async throws {
        guard let clientID = Self.clientID else { throw Failure.notConfigured }
        var closedByPerson = false
        let picker = ASWebAuthenticationSession(url: pickerURL, callbackURLScheme: Self.callbackScheme(for: clientID)) { _, _ in
            Task { @MainActor in closedByPerson = true }
        }
        picker.presentationContextProvider = self
        picker.prefersEphemeralWebBrowserSession = false
        webSession = picker
        guard picker.start() else { throw Failure.message("Google Photos could not open.") }
        defer { picker.cancel() }

        let interval = Self.seconds(session.pollingConfig?.pollInterval).map { min(10, max(1.5, $0)) } ?? 3
        let deadline = Date.now.addingTimeInterval(Self.seconds(session.pollingConfig?.timeoutIn).map { min(3600, max(30, $0)) } ?? 1200)
        var closedChecks = 0
        while true {
            if Date.now > deadline { throw Failure.message("Google Photos timed out. Try choosing your photos again.") }
            try await Task.sleep(for: .seconds(closedByPerson ? 0.75 : interval))
            let latest: PickerSession = try await request("\(Self.pickerAPI)/sessions/\(session.id)", token: token)
            if latest.mediaItemsSet == true { return }
            if closedByPerson {
                closedChecks += 1
                if closedChecks >= 2 { throw Failure.cancelled }
            }
        }
    }

    func pickedItems(sessionID: String, token: String) async throws -> [PickedItem] {
        struct Page: Decodable { let mediaItems: [PickedItem]?; let nextPageToken: String? }
        var items: [PickedItem] = []
        var pageToken: String?
        for _ in 0..<10 {
            var url = URLComponents(string: "\(Self.pickerAPI)/mediaItems")!
            url.queryItems = [.init(name: "sessionId", value: sessionID), .init(name: "pageSize", value: "100")]
            if let pageToken { url.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let page: Page = try await request(url.string!, token: token)
            items += page.mediaItems ?? []
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        return items
    }

    func download(_ item: PickedItem, into dir: URL, token: String) async throws -> URL {
        for suffix in ["=w4096-h4096", "=d"] {
            guard let url = URL(string: item.mediaFile.baseUrl + suffix) else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let reply: (Data, URLResponse)
            do {
                reply = try await urlSession.data(for: req)
            } catch {
                // A cancel is a cancel, not a failed download to retry with the next size.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                continue
            }
            let (data, response) = reply
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? item.mediaFile.mimeType ?? "image/jpeg"
            let ext = mime.contains("png") ? "png" : mime.contains("heic") || mime.contains("heif") ? "heic" : mime.contains("webp") ? "webp" : "jpg"
            let file = dir.appending(path: "\(UUID().uuidString).\(ext)")
            try data.write(to: file)
            return file
        }
        throw Failure.message("Couldn't download “\(item.mediaFile.filename ?? "photo")” from Google Photos.")
    }

    /// A downloaded pick as a Photo. Google's resized copies usually drop EXIF, so the capture
    /// date and camera settings come from the picker's metadata when the file has none.
    func makePhoto(_ item: PickedItem, url: URL, collectionID: UUID, sortIndex: Int) -> Photo {
        let info = PhotoImport.metadata(of: url, fallbackAsset: nil)
        let created = item.createTime.flatMap { string in
            (try? Date(string, strategy: .iso8601)) ?? ISO8601DateFormatter.withFractions.date(from: string)
        }
        let pm = item.mediaFile.mediaFileMetadata?.photoMetadata
        let googleExif = Photo.Exif(
            aperture: pm?.apertureFNumber.flatMap { $0 > 0 ? ($0 * 100).rounded() / 100 : nil },
            shutter: Self.seconds(pm?.exposureTime).flatMap(PhotoImport.formatShutter),
            iso: pm?.isoEquivalent.flatMap { $0 > 0 ? $0 : nil },
            focalLength: pm?.focalLength.flatMap { $0 > 0 ? Int($0.rounded()) : nil })
        let hasGoogleExif = googleExif.aperture != nil || googleExif.shutter != nil || googleExif.iso != nil || googleExif.focalLength != nil
        return Photo(id: UUID(), collectionID: collectionID, imageURL: url, rawURL: nil,
                     pixelWidth: info.width, pixelHeight: info.height, caption: nil,
                     capturedAt: info.capturedAt ?? created, exif: info.exif ?? (hasGoogleExif ? googleExif : nil),
                     sortIndex: sortIndex)
    }

    // MARK: - REST

    func request<T: Decodable>(_ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let data = try await send(url, token: token, method: method, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("GooglePhotos: couldn't decode \(T.self) from \(url): \(error)")
            throw Failure.message("Google Photos sent a reply Batches couldn't read.")
        }
    }

    @discardableResult
    func send(_ url: String, token: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            self.token = nil
            throw Failure.message("Your Google Photos session expired. Try again to reconnect.")
        }
        guard (200..<300).contains(status) else {
            struct APIError: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
            let detail = (try? JSONDecoder().decode(APIError.self, from: data))?.error?.message
            throw Failure.message(detail ?? "Google Photos returned HTTP \(status).")
        }
        return data
    }

    // MARK: - Helpers

    /// Google durations look like "3.5s".
    static func seconds(_ raw: String?) -> Double? {
        guard let raw, raw.hasSuffix("s"), let value = Double(raw.dropLast()), value > 0 else { return nil }
        return value
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension GooglePhotos: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
        }
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension KeyedDecodingContainer {
    /// A number sent either as a JSON number or as a numeric string; nil when absent or unreadable.
    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
