import XCTest
@testable import Batches

/// The grouping rules, on made-up libraries. The cases marked "review" are the ones the PR #8
/// review found grouping wrongly before.
final class SmartBatchesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private var counter = 0

    // Places.
    private let sf = (lat: 37.7749, lon: -122.4194)
    private let oakland = (lat: 37.8044, lon: -122.2712)
    private let maui = (lat: 20.80, lon: -156.33)
    private let tahoe = (lat: 39.0968, lon: -120.0324)
    private let la = (lat: 34.0522, lon: -118.2437)
    private let tokyo = (lat: 35.6762, lon: 139.6503)

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `count` photos `every` minutes apart from `start`, at `place` jittered by up to ~`spread` km.
    private func shoot(_ count: Int, from start: Date, every minutes: Double = 10,
                       at place: (lat: Double, lon: Double)?, spread km: Double = 0.2, batched: Bool = false) -> [SmartBatchItem] {
        (0..<count).map { i in
            counter += 1
            let jitter = km / 111 * (Double((counter * 7919) % 200) / 100 - 1)
            return SmartBatchItem(id: "p\(counter)", date: start.addingTimeInterval(Double(i) * minutes * 60),
                                  latitude: place.map { $0.lat + jitter }, longitude: place.map { $0.lon - jitter },
                                  isBatched: batched)
        }
    }

    private func group(_ items: [SmartBatchItem]) -> [SmartBatch] {
        SmartBatchGrouping.batches(from: items, calendar: calendar).sorted { $0.start < $1.start }
    }

    /// 30 ordinary days at home spread across a ~15 km city, 6 photos each.
    private func homeMonth(startDay: Int = 1, days: Int = 30, month: Int = 1) -> [SmartBatchItem] {
        (0..<days).flatMap { d -> [SmartBatchItem] in
            let spot = (lat: sf.lat + Double(d % 6 - 3) * 0.02, lon: sf.lon + Double(d % 5 - 2) * 0.02)
            return shoot(6, from: date(month, startDay, 12).addingTimeInterval(Double(d) * 86_400), at: spot)
        }
    }

    // MARK: Basics that already worked

    func testSixPhotosMakeABatchAndFiveDoNot() {
        XCTAssertEqual(group(shoot(6, from: date(3, 1, 10), at: sf)).count, 1)
        XCTAssertEqual(group(shoot(5, from: date(3, 1, 10), at: sf)).count, 0)
    }

    func testPartyAcrossMidnightStaysOneBatch() {
        let batches = group(shoot(12, from: date(3, 1, 22), every: 14, at: sf))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 12)
    }

    func testNearbyTownsSameDayMerge() {
        let items = shoot(6, from: date(3, 1, 10), at: sf) + shoot(6, from: date(3, 1, 14), at: oakland)
        XCTAssertEqual(group(items).count, 1)
    }

    func testBatchedPhotosAreNeverSuggested() {
        let items = shoot(10, from: date(3, 1, 10), at: sf, batched: true)
        XCTAssertTrue(group(items).isEmpty)
    }

    // MARK: Review fixes

    /// Review #1: a heavily photographed resort day must not become "home".
    func testResortCannotOutrankRealHome() {
        let items = homeMonth() + shoot(60, from: date(2, 10, 9), every: 5, at: maui, spread: 0.05)
        let home = try! XCTUnwrap(SmartBatchGrouping.home(of: items, calendar: calendar))
        XCTAssertLessThan(SmartBatchGrouping.distance(home, sf), 20_000, "home should be SF, got \(home)")

        let batches = group(items)
        let mauiBatch = try! XCTUnwrap(batches.first { $0.count == 60 })
        XCTAssertTrue(mauiBatch.isTrip)
        XCTAssertTrue(batches.filter { $0.count != 60 }.allSatisfy { !$0.isTrip }, "home days are not trips")
        XCTAssertTrue(batches.allSatisfy { $0.end.timeIntervalSince($0.start) < 86_400 * 2 }, "no month-long batches")
    }

    /// Review #1: home counts photos already in batches, so batching home days doesn't move home.
    func testHomeIncludesBatchedPhotos() {
        let items = homeMonth().map { var i = $0; i.isBatched = true; return i }
            + shoot(40, from: date(2, 10, 9), every: 5, at: maui)
        let batches = group(items)
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].isTrip, "Maui is still away from (batched) home")
    }

    /// Review #2: a trip day with no GPS stays part of the trip.
    func testNoLocationDayInsideTripJoinsIt() {
        let items = homeMonth()
            + shoot(8, from: date(2, 5, 10), at: tahoe)
            + shoot(8, from: date(2, 6, 10), at: nil)
            + shoot(8, from: date(2, 7, 10), at: tahoe)
        let trips = group(items).filter(\.isTrip)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.count, 24)
    }

    /// A no-location day after a trip, followed by home, isn't pulled into the trip.
    func testNoLocationDayAfterTripStaysApart() {
        let items = homeMonth()
            + shoot(8, from: date(2, 5, 10), at: tahoe)
            + shoot(8, from: date(2, 6, 10), at: nil)
            + shoot(8, from: date(2, 7, 10), at: sf)
        let batches = group(items).filter { $0.start >= date(2, 5, 0) }
        XCTAssertEqual(batches.map(\.count), [8, 8, 8])
        XCTAssertEqual(batches.map(\.isTrip), [true, false, false])
    }

    /// Review #3: two trips far apart, a day and a bit between them, stay two trips.
    func testFarApartTripsSplit() {
        let items = homeMonth()
            + shoot(10, from: date(2, 5, 10), at: tahoe)
            + shoot(10, from: date(2, 6, 16), at: la)
        let trips = group(items).filter(\.isTrip)
        XCTAssertEqual(trips.count, 2)
    }

    /// Review #3: the place is where photos were taken, not an average between two spots.
    func testPlaceIsBusiestSpotNotAverage() throws {
        let items = homeMonth()
            + shoot(20, from: date(2, 5, 9), every: 5, at: tahoe)
            + shoot(8, from: date(2, 5, 13), every: 5, at: (lat: 39.30, lon: -120.30))  // Truckee-ish, 30 km off
        let trip = try XCTUnwrap(group(items).first(where: \.isTrip))
        let spot = try XCTUnwrap(trip.latitude.flatMap { lat in trip.longitude.map { (lat: lat, lon: $0) } })
        XCTAssertLessThan(SmartBatchGrouping.distance(spot, tahoe), 2_000)
    }

    /// Review #3: across the date line the spot stays in Fiji, not the Atlantic.
    func testPlaceAcrossDateLine() throws {
        let east = shoot(4, from: date(3, 1, 10), at: (lat: -17.8, lon: 179.995), spread: 0)
        let west = shoot(3, from: date(3, 1, 11), at: (lat: -17.8, lon: -179.995), spread: 0)
        let batch = try XCTUnwrap(group(east + west).first)
        XCTAssertGreaterThan(abs(try XCTUnwrap(batch.longitude)), 179)
    }

    /// Review low: a photo every 80 minutes for days doesn't chain into one endless "day".
    func testSteadyTrickleDoesNotChainForDays() {
        let items = homeMonth() + shoot(54, from: date(2, 5, 8), every: 80, at: sf)
        let batches = group(items).filter { $0.start >= date(2, 5, 0) }
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.end.timeIntervalSince($0.start) <= SmartBatchGrouping.maxDaySpan })
    }

    func testLongTripIsCappedAt21Days() {
        let items = homeMonth()
            + (0..<30).flatMap { d in shoot(6, from: date(3, 1, 10).addingTimeInterval(Double(d) * 86_400), at: tahoe) }
        let trips = group(items).filter(\.isTrip)
        XCTAssertGreaterThanOrEqual(trips.count, 2)
        XCTAssertTrue(trips.allSatisfy { $0.end.timeIntervalSince($0.start) <= SmartBatchGrouping.maxTripSpan })
    }

    func testMultiDayTripStillJoins() {
        let items = homeMonth()
            + shoot(8, from: date(2, 5, 10), at: tahoe)
            + shoot(8, from: date(2, 6, 10), at: tahoe)
            + shoot(8, from: date(2, 7, 10), at: tahoe)
        let trips = group(items).filter(\.isTrip)
        XCTAssertEqual(trips.map(\.count), [24])
    }

    func testLongHaulTripAfterHomeDay() {
        let items = homeMonth()
            + shoot(8, from: date(2, 5, 8), at: sf)
            + shoot(10, from: date(2, 6, 9), at: tokyo)
            + shoot(10, from: date(2, 7, 9), at: tokyo)
        let recent = group(items).filter { $0.start >= date(2, 5, 0) }
        XCTAssertEqual(recent.map(\.isTrip), [false, true])
        XCTAssertEqual(recent.last?.count, 20)
    }
}
