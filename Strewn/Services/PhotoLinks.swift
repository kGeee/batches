import CryptoKit
import Foundation

/// Hands out signed links to shared copies, only for photos about to be shown. Requests from
/// many photos on screen at once are gathered into small groups: signing every copy of every
/// photo in one call took seconds and could time out, leaving every photo blank.
actor PhotoLinks {
    typealias Signer = @Sendable ([String]) async throws -> [String: URL]

    static let shared = PhotoLinks()
    /// Set once by the backend at startup, before any photo is drawn. Nil on the demo backend,
    /// whose photos have no shared copies.
    nonisolated(unsafe) static var signer: Signer?
    /// How long a signed link lasts, in seconds. docs/storage-plan.md promises six hours.
    static let lifetime = 6 * 3600

    private static let batchSize = 50
    private static let maxRunning = 3

    private var links: [String: (url: URL, reuseUntil: Date)] = [:]
    private var waiting: [String: [CheckedContinuation<URL?, Never>]] = [:]
    private var queue: [String] = []
    private var running = 0
    private var flushScheduled = false

    func url(for path: String) async -> URL? {
        if let link = links[path], link.reuseUntil > .now { return link.url }
        return await withCheckedContinuation { continuation in
            if waiting[path] == nil { queue.append(path) }
            waiting[path, default: []].append(continuation)
            scheduleFlush()
        }
    }

    /// Forgets a link the server refused, so the next request signs a new one.
    func invalidate(_ path: String) {
        links[path] = nil
    }

    func clear() {
        links = [:]
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            // Long enough for everything appearing in the same frame to join one request.
            try? await Task.sleep(for: .milliseconds(40))
            flush()
        }
    }

    private func flush() {
        flushScheduled = false
        while running < Self.maxRunning, !queue.isEmpty {
            let batch = Array(queue.prefix(Self.batchSize))
            queue.removeFirst(batch.count)
            running += 1
            Task { await sign(batch) }
        }
    }

    private func sign(_ batch: [String]) async {
        var signed: [String: URL] = [:]
        if let signer = Self.signer {
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(800)) }
                if let result = try? await signer(batch) {
                    signed = result
                    break
                }
            }
        }
        let reuseUntil = Date.now.addingTimeInterval(TimeInterval(Self.lifetime - 3600))
        for path in batch {
            if let url = signed[path] { links[path] = (url, reuseUntil) }
            for continuation in waiting.removeValue(forKey: path) ?? [] {
                continuation.resume(returning: signed[path])
            }
        }
        running -= 1
        if !queue.isEmpty { scheduleFlush() }
    }
}

/// Shared copies already downloaded, kept in Caches under their storage path. A copy at a given
/// path never changes (a new edit gets a new folder), so it stays valid however often its signed
/// link changes. iOS may clear this folder when space runs low; photos then download again.
final class SharedPhotoDisk: @unchecked Sendable {
    static let shared = SharedPhotoDisk()

    private static let byteLimit = 300 * 1024 * 1024
    private static let storesBetweenTrims = 100

    private let folder: URL
    private let lock = NSLock()
    private var storesSinceTrim = 0

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "SharedPhotos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task.detached(priority: .utility) { [self] in trim() }
    }

    private func file(for path: String) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: name)
    }

    func data(for path: String) -> Data? {
        let url = file(for: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Marks it recently used, so trimming removes what hasn't been looked at for longest.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, for path: String) {
        try? data.write(to: file(for: path), options: .atomic)
        let due = lock.withLock {
            storesSinceTrim += 1
            if storesSinceTrim >= Self.storesBetweenTrims { storesSinceTrim = 0; return true }
            return false
        }
        if due { Task.detached(priority: .utility) { [self] in trim() } }
    }

    /// For signing out: the next person on this phone shouldn't inherit these photos.
    func clear() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > Self.byteLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
