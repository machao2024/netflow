import XCTest
@testable import NetFlowCore

final class TrafficTests: XCTestCase {
    private func snapshot(_ time: Double, down: UInt64, up: UInt64 = 0, name: String = "en0", index: UInt32 = 1, uptime: Double? = nil) -> CounterSnapshot {
        CounterSnapshot(date: Date(timeIntervalSince1970: time), uptime: uptime ?? time,
                        interfaces: [InterfaceCounter(name: name, index: index, received: down, sent: up)])
    }
    func testFirstReadingIsOnlyBaseline() {
        var accumulator = TrafficAccumulator()
        XCTAssertNil(accumulator.consume(snapshot(60, down: 8_000_000_000)))
        let sample = accumulator.consume(snapshot(61, down: 8_000_001_234))!
        XCTAssertEqual(sample.receivedPerSecond, 1234)
        XCTAssertEqual(sample.buckets[0].received, 1234)
    }
    func testMonotonicElapsedDrivesSpeed() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 0, uptime: 1))
        let sample = accumulator.consume(snapshot(62, down: 400, uptime: 3))!
        XCTAssertEqual(sample.receivedPerSecond, 200)
    }
    func testBoundarySplitPreservesEveryByte() {
        let buckets = TrafficAccumulator.split(start: Date(timeIntervalSince1970: 119.25), end: Date(timeIntervalSince1970: 120.25), received: 101, sent: 37)
        XCTAssertEqual(buckets.map(\.received), [75, 26])
        XCTAssertEqual(buckets.map(\.sent), [27, 10])
        XCTAssertEqual(buckets.map(\.coveredSeconds), [0.75, 0.25])
        XCTAssertEqual(buckets.map { $0.start.timeIntervalSince1970 }, [60, 120])
    }
    func testExactMinuteEndDoesNotCreateEmptyNextMinute() {
        let rows = TrafficAccumulator.split(start: Date(timeIntervalSince1970: 59), end: Date(timeIntervalSince1970: 60), received: 12, sent: 3)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].start.timeIntervalSince1970, 0)
    }
    func testInterfaceReplacementNeverIncludesPriorUsage() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 1000))
        XCTAssertNil(accumulator.consume(snapshot(61, down: 9_000_000, name: "en5", index: 5)))
        XCTAssertEqual(accumulator.consume(snapshot(62, down: 9_000_032, name: "en5", index: 5))?.receivedPerSecond, 32)
    }
    func testCounterResetRebaselinesBothDirections() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 1000, up: 500))
        XCTAssertNil(accumulator.consume(snapshot(61, down: 20, up: 30)))
        let sample = accumulator.consume(snapshot(62, down: 42, up: 63))!
        XCTAssertEqual(sample.receivedPerSecond, 22); XCTAssertEqual(sample.sentPerSecond, 33)
    }
    func testInterfaceIndexChangeResetsBaseline() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 100, index: 1))
        XCTAssertNil(accumulator.consume(snapshot(61, down: 10000, index: 2)))
    }
    func testMultiplePhysicalInterfacesSumOnce() {
        var accumulator = TrafficAccumulator()
        let first = CounterSnapshot(date: Date(timeIntervalSince1970: 60), uptime: 60, interfaces: [
            InterfaceCounter(name: "en0", index: 1, received: 100, sent: 20),
            InterfaceCounter(name: "en5", index: 5, received: 200, sent: 30)])
        let second = CounterSnapshot(date: Date(timeIntervalSince1970: 61), uptime: 61, interfaces: [
            InterfaceCounter(name: "en0", index: 1, received: 120, sent: 25),
            InterfaceCounter(name: "en5", index: 5, received: 240, sent: 40)])
        _ = accumulator.consume(first)
        let sample = accumulator.consume(second)!
        XCTAssertEqual(sample.receivedPerSecond, 60); XCTAssertEqual(sample.sentPerSecond, 15)
        XCTAssertEqual(sample.buckets[0].coveredSeconds, 1)
    }
    func testSleepAndClockChangesAreGaps() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 100))
        XCTAssertNil(accumulator.consume(snapshot(3600, down: 9000)))
        XCTAssertEqual(accumulator.consume(snapshot(3601, down: 9010))?.receivedPerSecond, 10)
        XCTAssertNil(accumulator.consume(snapshot(3500, down: 9020, uptime: 3602)))
    }
    func testPauseResetExcludesPausedTraffic() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 100)); accumulator.reset()
        XCTAssertNil(accumulator.consume(snapshot(61, down: 5000)))
        XCTAssertEqual(accumulator.consume(snapshot(62, down: 5100))?.receivedPerSecond, 100)
    }
    func testVirtualInterfacesExcludedFromAutomaticSelection() {
        for name in ["lo0", "utun0", "awdl0", "llw0", "bridge0", "en", "enX"] { XCTAssertFalse(NetworkReader.isPhysicalName(name), name) }
        for name in ["en0", "en5", "en12"] { XCTAssertTrue(NetworkReader.isPhysicalName(name), name) }
    }
    func testZeroTrafficStillHasCoverage() {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(snapshot(60, down: 100))
        let sample = accumulator.consume(snapshot(61, down: 100))!
        XCTAssertEqual(sample.receivedPerSecond, 0); XCTAssertTrue(sample.buckets[0].hasSamples)
    }
    func testFormattingUsesDecimalBytes() {
        XCTAssertEqual(TrafficFormat.bytes(1000), "1.00 KB")
        XCTAssertEqual(TrafficFormat.speed(1_500_000), "1.50 MB/s")
        XCTAssertEqual(TrafficFormat.bytes(0), "0 B")
    }
}

final class StoreTests: XCTestCase {
    private let minute = Date(timeIntervalSince1970: 1_800_000_000)
    private var range: DateInterval { DateInterval(start: minute, duration: 3600) }
    func testMultipleFlushesAndRestartWithinSameMinute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        var store: TrafficStore? = try TrafficStore(path: path)
        try store!.merge([TrafficBucket(start: minute, received: 100, sent: 50, coveredSeconds: 10)])
        store = nil
        store = try TrafficStore(path: path)
        try store!.merge([TrafficBucket(start: minute, received: 300, sent: 60, coveredSeconds: 12)])
        let rows = try store!.read(in: range)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].received, 400)
        XCTAssertEqual(rows[0].sent, 110); XCTAssertEqual(rows[0].coveredSeconds, 22)
    }
    func testFailedBatchRollsBackWithoutPartialAdditions() throws {
        let store = try TrafficStore(path: ":memory:")
        XCTAssertThrowsError(try store.merge([
            TrafficBucket(start: minute, received: 50, sent: 20, coveredSeconds: 1),
            TrafficBucket(start: minute.addingTimeInterval(60), received: -1, coveredSeconds: 1)
        ]))
        XCTAssertEqual(try store.total(in: range).total, 0)
        try store.merge([TrafficBucket(start: minute, received: 50, sent: 20, coveredSeconds: 1)])
        XCTAssertEqual(try store.total(in: range).total, 70)
    }
    func testRangeIsHalfOpenAndMissingMinuteHasNoCoverage() throws {
        let store = try TrafficStore(path: ":memory:")
        try store.merge([TrafficBucket(start: minute, received: 100, coveredSeconds: 30),
                         TrafficBucket(start: range.end, received: 999, coveredSeconds: 1)])
        XCTAssertEqual(try store.total(in: range).received, 100)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rows = TrafficStore.aggregate(try store.read(in: range), by: .minute, in: range, calendar: calendar)
        XCTAssertEqual(rows.count, 60); XCTAssertFalse(rows[1].hasSamples); XCTAssertTrue(rows[0].hasSamples)
    }
    func testMidnightAggregationInShanghai() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let split = TrafficAccumulator.split(start: midnight.addingTimeInterval(-0.5), end: midnight.addingTimeInterval(0.5), received: 100, sent: 50)
        let beforeRange = calendar.dateInterval(of: .day, for: midnight.addingTimeInterval(-1))!
        let afterRange = calendar.dateInterval(of: .day, for: midnight)!
        let before = TrafficStore.aggregate(split, by: .day, in: beforeRange, calendar: calendar)
        let after = TrafficStore.aggregate(split, by: .day, in: afterRange, calendar: calendar)
        XCTAssertEqual(before[0].received, 50); XCTAssertEqual(after[0].received, 50)
        XCTAssertEqual(before[0].sent, 25); XCTAssertEqual(after[0].sent, 25)
    }
    func testDSTCalendarDaysHave23And25Hours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, expected) in [(3, 8, 23), (11, 1, 25)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let range = HistoryGranularity.hour.interval(containing: date, calendar: calendar)
            let rows = TrafficStore.aggregate([], by: .hour, in: range, calendar: calendar)
            XCTAssertEqual(rows.count, expected)
            XCTAssertEqual(Set(rows.map(\.id)).count, expected)
        }
    }
    func testHourlyAndDailyTotalsMatchMinutes() throws {
        let store = try TrafficStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: minute)
        let range = DateInterval(start: start, duration: 86400)
        let input = (0..<1440).map { TrafficBucket(start: start.addingTimeInterval(Double($0) * 60), received: Int64($0), sent: 2, coveredSeconds: 60) }
        try store.merge(input)
        let minutes = try store.read(in: range)
        let hours = TrafficStore.aggregate(minutes, by: .hour, in: range, calendar: calendar)
        let days = TrafficStore.aggregate(minutes, by: .day, in: range, calendar: calendar)
        XCTAssertEqual(hours.count, 24); XCTAssertEqual(days.count, 1)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.total }, days[0].total)
        XCTAssertEqual(try store.total(in: range).total, days[0].total)
        XCTAssertEqual(days[0].coveredSeconds, 86400)
    }
    func testCSVIncludesRawBytesOffsetAndMissingState() {
        let csv = TrafficStore.csv([TrafficBucket(start: minute, received: 123, sent: 4, coveredSeconds: 5),
                                    TrafficBucket(start: minute.addingTimeInterval(60))], granularity: .minute)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}时间")); XCTAssertTrue(csv.contains(",123,4,127,5.00,已记录"))
        XCTAssertTrue(csv.contains(",0,0,0,0.00,未记录"))
    }
}
