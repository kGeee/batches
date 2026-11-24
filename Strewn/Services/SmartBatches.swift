import CoreLocation
import Foundation
import Photos
import UIKit

/// One suggested batch: photos from the library that were taken together, found on this phone.
/// Nothing about the library (dates, places, photos) leaves the device to make these.
struct SmartBatch: Identifiable, Hashable {
    /// The first photo's asset id, so a suggestion keeps its identity across reloads.
    let id: String
    /// Photos Library asset ids, oldest first.
    var assetIDs: [String]
    var start: Date
    var end: Date
    /// Average position of the photos that have one; nil when none do.
    var latitude: Double?
    var longitude: Double?
    /// Every part of it was taken far from home, over one or more days.
    var isTrip: Bool

    var count: Int { assetIDs.count }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// "Oct 12" or "Oct 12 – 14" (or across months, "Oct 30 – Nov 2").
    var dateLabel: String {
        let calendar = Calendar.current
        let day = Date.FormatStyle().month(.abbreviated).day()
        if calendar.isDate(start, inSameDayAs: end) { return start.formatted(day) }
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(start.formatted(day)) – \(end.formatted(.dateTime.day()))"
        }
        return "\(start.formatted(day)) – \(end.formatted(day))"
    }

    /// The name the batch starts with: "Big Sur, Oct 12", or just the date without a place.
    func suggestedTitle(place: String?) -> String {
        guard let place, !place.isEmpty else { return dateLabel }
        return "\(place), \(dateLabel)"
    }
}

/// What the grouping needs to know about one photo. Plain values, so the grouping can run
/// off the main thread and be checked without a photo library.
struct SmartBatchItem: Hashable, Sendable {
    let id: String
    let date: Date
    var latitude: Double? = nil
    var longitude: Double? = nil
}

/// Groups photos into suggested batches by when and where they were taken.
///
/// 1. Moments: a new group starts wherever two photos are more than `momentGap` apart.
/// 2. Days: neighbouring moments join when they're under `dayGap` apart and close together.
/// 3. Trips: neighbouring groups taken far from home join, even across nights.
/// 4. Only groups of at least `minimumCount` photos are suggested, newest first.
///
/// The numbers are starting points to tune on real libraries.
enum SmartBatchGrouping {
    static let momentGap: TimeInterval = 90 * 60
    static let dayGap: TimeInterval = 6 * 60 * 60
    static let tripGap: TimeInterval = 36 * 60 * 60
    static let nearbyMeters: Double = 25_000
    static let awayFromHomeMeters: Double = 80_000
    static let minimumCount = 6

    private struct Group {
        var items: [SmartBatchItem]
        var center: (lat: Double, lon: Double)? {
            let located = items.compactMap { item -> (Double, Double)? in
                guard let lat = item.latitude, let lon = item.longitude else { return nil }
                return (lat, lon)
            }
            guard !located.isEmpty else { return nil }
            let n = Double(located.count)
            return (located.map { $0.0 }.reduce(0, +) / n, located.map { $0.1 }.reduce(0, +) / n)
        }
        var start: Date { items.first!.date }
        var end: Date { items.last!.date }
    }

    static func batches(from items: [SmartBatchItem], home: (lat: Double, lon: Double)? = nil) -> [SmartBatch] {
        let sorted = items.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }
        let home = home ?? Self.home(of: sorted)

        // 1. Moments.
        var moments: [Group] = []
        for item in sorted {
            if let last = moments.last?.items.last, item.date.timeIntervalSince(last.date) <= momentGap {
                moments[moments.count - 1].items.append(item)
            } else {
                moments.append(Group(items: [item]))
            }
        }

        // 2. Days: join moments that are close in time and not clearly far apart.
        var days: [Group] = []
        for moment in moments {
            if let last = days.last,
               moment.start.timeIntervalSince(last.end) <= dayGap,
               !isFar(last.center, moment.center, beyond: nearbyMeters) {
                days[days.count - 1].items += moment.items
            } else {
                days.append(moment)
            }
        }

        // 3. Trips: join neighbours that were both taken away from home.
        var groups: [(group: Group, isTrip: Bool)] = []
        for day in days {
            let away = isAway(day.center, home: home)
            if let last = groups.last, last.isTrip, away,
               day.start.timeIntervalSince(last.group.end) <= tripGap {
                groups[groups.count - 1].group.items += day.items
            } else {
                groups.append((group: day, isTrip: away))
            }
        }

        // 4. Big enough to feel like a pile, newest first.
        return groups
            .filter { $0.group.items.count >= minimumCount }
            .map { entry in
                let center = entry.group.center
                return SmartBatch(id: entry.group.items[0].id, assetIDs: entry.group.items.map(\.id),
                                  start: entry.group.start, end: entry.group.end,
                                  latitude: center?.lat, longitude: center?.lon, isTrip: entry.isTrip)
            }
            .sorted { $0.end > $1.end }
    }

    /// Where most photos are taken: the busiest cell of a roughly 1 km grid.
    static func home(of items: [SmartBatchItem]) -> (lat: Double, lon: Double)? {
        var counts: [String: (count: Int, lat: Double, lon: Double)] = [:]
        for item in items {
            guard let lat = item.latitude, let lon = item.longitude else { continue }
            let key = "\((lat * 100).rounded()),\((lon * 100).rounded())"
            let entry = counts[key] ?? (0, (lat * 100).rounded() / 100, (lon * 100).rounded() / 100)
            counts[key] = (entry.count + 1, entry.lat, entry.lon)
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }) else { return nil }
        return (best.lat, best.lon)
    }

    /// A group is away when it has a place and that place is far from home. Without a home
    /// (no located photos at all) nothing counts as a trip.
    private static func isAway(_ center: (lat: Double, lon: Double)?, home: (lat: Double, lon: Double)?) -> Bool {
        guard let center, let home else { return false }
        return distance(center, home) > awayFromHomeMeters
    }

    /// Only two known places can be far apart; a group without a place joins on time alone.
    private static func isFar(_ a: (lat: Double, lon: Double)?, _ b: (lat: Double, lon: Double)?, beyond meters: Double) -> Bool {
        guard let a, let b else { return false }
        return distance(a, b) > meters
    }

    /// Great-circle distance in meters.
    static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

/// Suggested batches for the New batch sheet: library access, the grouping, and place names.
@MainActor
@Observable
final class SmartBatchSuggestions {
    enum Access { case notAsked, full, limited, denied }

    /// How far back suggestions look.
    static let lookBackMonths = 12

    private(set) var access: Access = SmartBatchSuggestions.currentAccess()
    private(set) var batches: [SmartBatch] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Place names by batch id, filled in as cards come on screen.
    private(set) var places: [String: String] = [:]
    @ObservationIgnored private var geocoding: Set<String> = []
    @ObservationIgnored private let geocoder = CLGeocoder()

    nonisolated static func currentAccess() -> Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    var canSuggest: Bool { access == .full || access == .limited }

    /// Asks iOS for library access. Only called from the card the person taps.
    func requestAccess(excluding batched: Set<String>) async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.currentAccess()
        await load(excluding: batched)
    }

    /// Re-reads access (it can change in Settings) and regroups the library.
    func load(excluding batched: Set<String>) async {
        access = Self.currentAccess()
        guard canSuggest else { batches = []; return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let since = Calendar.current.date(byAdding: .month, value: -Self.lookBackMonths, to: .now) ?? .distantPast
        batches = await Task.detached(priority: .userInitiated) {
            SmartBatchGrouping.batches(from: Self.libraryItems(since: since, excluding: batched))
        }.value
    }

    /// Still photos from your own library: no screenshots, no hidden photos, one photo per
    /// burst (its chosen frame), and nothing already in one of your batches.
    nonisolated static func libraryItems(since: Date, excluding batched: Set<String>) -> [SmartBatchItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@",
                                        PHAssetMediaType.image.rawValue, since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        var items: [SmartBatchItem] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate,
                  !asset.mediaSubtypes.contains(.photoScreenshot),
                  !batched.contains(asset.localIdentifier) else { return }
            let coordinate = asset.location?.coordinate
            items.append(SmartBatchItem(id: asset.localIdentifier, date: date,
                                        latitude: coordinate?.latitude, longitude: coordinate?.longitude))
        }
        return items
    }

    /// Looks up a place name for a batch once, when its card comes on screen. Reverse
    /// geocoding goes over the network and is rate limited, so one lookup runs at a time.
    func nameIfNeeded(_ batch: SmartBatch) async {
        guard places[batch.id] == nil, !geocoding.contains(batch.id), let location = batch.location else { return }
        geocoding.insert(batch.id)
        defer { geocoding.remove(batch.id) }
        while geocoder.isGeocoding {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        // A trip reads better by its region; a day out by its town.
        let name = batch.isTrip
            ? (placemark.locality ?? placemark.administrativeArea ?? placemark.name)
            : (placemark.locality ?? placemark.name ?? placemark.administrativeArea)
        if let name, !name.isEmpty { places[batch.id] = name }
    }

    func assets(for batch: SmartBatch) -> [PHAsset] {
        Self.assets(withIDs: batch.assetIDs)
    }

    /// Assets in the order of `ids`, skipping any that are gone from the library.
    nonisolated static func assets(withIDs ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return ids.compactMap { byID[$0] }
    }

    /// Opens iOS's sheet for adding photos to a limited library, then regroups.
    func chooseMorePhotos(excluding batched: Set<String>) {
        guard let top = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { [weak self] _ in
            Task { @MainActor in await self?.load(excluding: batched) }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.compactMap(\.keyWindow).first?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// Small images of library photos for the suggestion cards and the review grid.
enum LibraryThumbnails {
    static let manager = PHCachingImageManager()

    /// An aspect-fit image no bigger than `maxPixelSide`. Delivers the final image only, so a
    /// fast scroll doesn't flash blurry previews; iCloud photos are allowed to download.
    static func image(for asset: PHAsset, maxPixelSide: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = maxPixelSide / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1))
        let size = CGSize(width: CGFloat(asset.pixelWidth) * min(1, scale), height: CGFloat(asset.pixelHeight) * min(1, scale))
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
