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
    /// The busiest spot among the photos that have a place (not an average, which can land
    /// somewhere nobody went); nil when none do.
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
    /// Already in one of your batches: still counts toward finding home, never suggested again.
    var isBatched = false

    var coordinate: (lat: Double, lon: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }
}

/// Groups photos into suggested batches by when and where they were taken.
///
/// 1. Moments: a new group starts wherever two photos are more than `momentGap` apart.
/// 2. Days: neighbouring moments join when they're under `dayGap` apart, close together, and
///    the result still spans less than `maxDaySpan`.
/// 3. Trips: neighbouring days taken far from home join, even across nights, as long as each
///    day is within `tripHopMeters` of the last and the trip stays under `maxTripSpan`. Days
///    with no location in the middle of a trip go with it.
/// 4. Only groups of at least `minimumCount` photos are suggested, newest first.
///
/// Home is where you took photos on the most different days, so a heavily photographed
/// holiday spot can't outrank where you live. The numbers are starting points to tune on real
/// libraries.
enum SmartBatchGrouping {
    static let momentGap: TimeInterval = 90 * 60
    static let dayGap: TimeInterval = 6 * 60 * 60
    static let maxDaySpan: TimeInterval = 20 * 60 * 60
    static let tripGap: TimeInterval = 36 * 60 * 60
    static let maxTripSpan: TimeInterval = 21 * 24 * 60 * 60
    static let nearbyMeters: Double = 25_000
    static let awayFromHomeMeters: Double = 80_000
    static let tripHopMeters: Double = 400_000
    static let minimumCount = 6
    /// Grid sizes in degrees: about 11 km for home, about 1.1 km for naming a batch's place.
    static let homeCell = 0.1
    static let placeCell = 0.01

    struct Group {
        var items: [SmartBatchItem]
        /// The middle of the busiest ~1 km cell among located photos.
        var center: (lat: Double, lon: Double)? { SmartBatchGrouping.busiestSpot(items.compactMap(\.coordinate)) }
        var start: Date { items.first!.date }
        var end: Date { items.last!.date }
        var span: TimeInterval { end.timeIntervalSince(start) }
    }

    /// `items` may include photos already in batches: they help find home, then are left out.
    static func batches(from items: [SmartBatchItem], home: (lat: Double, lon: Double)? = nil,
                        calendar: Calendar = .current) -> [SmartBatch] {
        let all = items.sorted { $0.date < $1.date }
        let home = home ?? Self.home(of: all, calendar: calendar)
        let sorted = all.filter { !$0.isBatched }
        guard !sorted.isEmpty else { return [] }

        // 1. Moments.
        var moments: [Group] = []
        for item in sorted {
            if let last = moments.last, let lastItem = last.items.last,
               item.date.timeIntervalSince(lastItem.date) <= momentGap,
               item.date.timeIntervalSince(last.start) <= maxDaySpan {
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
               moment.end.timeIntervalSince(last.start) <= maxDaySpan,
               !isFar(last.center, moment.center, beyond: nearbyMeters) {
                days[days.count - 1].items += moment.items
            } else {
                days.append(moment)
            }
        }

        // 3. Trips. Days with no location wait in `neutral` until the next located day says
        //    whether the trip carried on through them.
        var groups: [(group: Group, isTrip: Bool)] = []
        var neutral: [Group] = []
        var lastTripSpot: (lat: Double, lon: Double)?
        func flushNeutral() {
            groups += neutral.map { (group: $0, isTrip: false) }
            neutral = []
        }
        for day in days {
            guard let center = day.center else {
                if let last = groups.last, last.isTrip, neutral.isEmpty || neutral.last!.end <= day.start,
                   day.start.timeIntervalSince(neutral.last?.end ?? last.group.end) <= tripGap {
                    neutral.append(day)
                } else {
                    flushNeutral()
                    groups.append((group: day, isTrip: false))
                }
                continue
            }
            let away = isAway(center, home: home)
            if away, let last = groups.last, last.isTrip,
               day.start.timeIntervalSince(neutral.last?.end ?? last.group.end) <= tripGap,
               day.end.timeIntervalSince(last.group.start) <= maxTripSpan,
               !isFar(lastTripSpot, center, beyond: tripHopMeters) {
                groups[groups.count - 1].group.items += neutral.flatMap(\.items) + day.items
                neutral = []
            } else {
                flushNeutral()
                groups.append((group: day, isTrip: away))
            }
            if away { lastTripSpot = center }
        }
        flushNeutral()

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

    /// Where you take photos on the most different days, on a roughly 11 km grid: a week at a
    /// resort is seven days there, a year at home is hundreds. Ties go to the cell with more
    /// photos. The spot returned is the busiest ~1 km cell inside the winning cell.
    static func home(of items: [SmartBatchItem], calendar: Calendar = .current) -> (lat: Double, lon: Double)? {
        struct Cell { var days: Set<DateComponents> = []; var points: [(lat: Double, lon: Double)] = [] }
        var cells: [String: Cell] = [:]
        for item in items {
            guard let point = item.coordinate else { continue }
            let key = cellKey(point, size: homeCell)
            cells[key, default: Cell()].days.insert(calendar.dateComponents([.year, .month, .day], from: item.date))
            cells[key, default: Cell()].points.append(point)
        }
        let best = cells.values.max { a, b in
            a.days.count != b.days.count ? a.days.count < b.days.count : a.points.count < b.points.count
        }
        return best.flatMap { busiestSpot($0.points) }
    }

    /// The mean of the photos in the busiest ~1 km cell. Averaging only within one small cell
    /// keeps the spot somewhere a photo was actually taken (and works across the date line).
    static func busiestSpot(_ points: [(lat: Double, lon: Double)]) -> (lat: Double, lon: Double)? {
        guard !points.isEmpty else { return nil }
        var cells: [String: [(lat: Double, lon: Double)]] = [:]
        for point in points { cells[cellKey(point, size: placeCell), default: []].append(point) }
        let busiest = cells.values.max { $0.count < $1.count }!
        let n = Double(busiest.count)
        return (busiest.map(\.lat).reduce(0, +) / n, busiest.map(\.lon).reduce(0, +) / n)
    }

    private static func cellKey(_ point: (lat: Double, lon: Double), size: Double) -> String {
        "\((point.lat / size).rounded(.down)),\((point.lon / size).rounded(.down))"
    }

    /// Far from home. Without a home (no located photos at all) nothing counts as a trip.
    private static func isAway(_ center: (lat: Double, lon: Double), home: (lat: Double, lon: Double)?) -> Bool {
        guard let home else { return false }
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
    @ObservationIgnored private var nameQueue: [SmartBatch] = []
    @ObservationIgnored private var namingLoop: Task<Void, Never>?
    /// Batches whose place lookup failed this session.
    @ObservationIgnored private var unnamable: Set<String> = []
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
    /// burst (its chosen frame). Photos already in one of your batches are flagged, not dropped.
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
            guard let date = asset.creationDate, !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            let coordinate = asset.location?.coordinate
            // Batched photos stay in the list, flagged, so they still help find home.
            items.append(SmartBatchItem(id: asset.localIdentifier, date: date,
                                        latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                                        isBatched: batched.contains(asset.localIdentifier)))
        }
        return items
    }

    /// Asks for a place name for a batch once, when its card comes on screen. Reverse
    /// geocoding goes over the network and is rate limited, so requests wait in one queue and a
    /// single loop works through it, one lookup at a time. A lookup that fails isn't retried
    /// this session, so scrolling back and forth doesn't spend the rate limit.
    func nameIfNeeded(_ batch: SmartBatch) {
        guard places[batch.id] == nil, !unnamable.contains(batch.id), batch.location != nil,
              !nameQueue.contains(where: { $0.id == batch.id }) else { return }
        nameQueue.append(batch)
        guard namingLoop == nil else { return }
        namingLoop = Task { [weak self] in
            while let self, !self.nameQueue.isEmpty {
                let next = self.nameQueue.removeFirst()
                await self.lookUpName(next)
            }
            self?.namingLoop = nil
        }
    }

    /// Stops naming when the sheet goes away; queued cards are asked for again next time.
    func stopNaming() {
        namingLoop?.cancel()
        namingLoop = nil
        nameQueue = []
    }

    private func lookUpName(_ batch: SmartBatch) async {
        guard places[batch.id] == nil, let location = batch.location, !Task.isCancelled else { return }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            if !Task.isCancelled { unnamable.insert(batch.id) }
            return
        }
        // A trip reads better by its region; a day out by its town.
        let name = batch.isTrip
            ? (placemark.locality ?? placemark.administrativeArea ?? placemark.name)
            : (placemark.locality ?? placemark.name ?? placemark.administrativeArea)
        if let name, !name.isEmpty { places[batch.id] = name } else { unnamable.insert(batch.id) }
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
