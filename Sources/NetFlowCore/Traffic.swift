import Foundation

public struct InterfaceCounter: Equatable {
    public let name: String
    public let index: UInt32
    public let received: UInt64
    public let sent: UInt64
    public let isUp: Bool

    public init(name: String, index: UInt32 = 1, received: UInt64, sent: UInt64, isUp: Bool = true) {
        self.name = name; self.index = index; self.received = received; self.sent = sent; self.isUp = isUp
    }
}

public struct CounterSnapshot {
    public let date: Date
    public let uptime: TimeInterval
    public let interfaces: [InterfaceCounter]
    public init(date: Date, uptime: TimeInterval, interfaces: [InterfaceCounter]) {
        self.date = date; self.uptime = uptime; self.interfaces = interfaces
    }
}

public struct TrafficBucket: Equatable, Identifiable {
    public let start: Date
    public var received: Int64
    public var sent: Int64
    public var coveredSeconds: Double
    public var id: Date { start }
    public var total: Int64 { received + sent }
    public var hasSamples: Bool { coveredSeconds > 0 }

    public init(start: Date, received: Int64 = 0, sent: Int64 = 0, coveredSeconds: Double = 0) {
        self.start = start; self.received = received; self.sent = sent; self.coveredSeconds = coveredSeconds
    }
}

public struct TrafficSample {
    public let receivedPerSecond: Double
    public let sentPerSecond: Double
    public let buckets: [TrafficBucket]
}

/// An interface's first reading establishes a baseline, never historical usage.
public struct TrafficAccumulator {
    private var previous: CounterSnapshot?
    public init() {}
    public mutating func reset() { previous = nil }

    public mutating func consume(_ current: CounterSnapshot) -> TrafficSample? {
        defer { previous = current }
        guard let previous else { return nil }
        let elapsed = current.uptime - previous.uptime
        let wallElapsed = current.date.timeIntervalSince(previous.date)
        // Sleep, clock changes, and suspended sampling cannot be assigned to minutes reliably.
        guard elapsed > 0, elapsed <= 10, wallElapsed > 0,
              abs(wallElapsed - elapsed) < 2 else { return nil }
        let old = Dictionary(uniqueKeysWithValues: previous.interfaces.map { ($0.name, $0) })
        var received: UInt64 = 0, sent: UInt64 = 0
        var hasContinuousInterface = false
        for item in current.interfaces {
            guard let before = old[item.name], before.index == item.index,
                  before.isUp, item.isUp else { continue }
            // Recreated interfaces and counter resets start a fresh baseline.
            guard item.received >= before.received, item.sent >= before.sent else { continue }
            received += item.received - before.received
            sent += item.sent - before.sent
            hasContinuousInterface = true
        }
        guard hasContinuousInterface else { return nil }
        let buckets = Self.split(start: previous.date, end: current.date,
                                 received: Int64(clamping: received), sent: Int64(clamping: sent))
        return TrafficSample(receivedPerSecond: Double(received) / elapsed,
                             sentPerSecond: Double(sent) / elapsed, buckets: buckets)
    }

    /// Split a sampling interval over UTC minute boundaries, preserving byte totals exactly.
    public static func split(start: Date, end: Date, received: Int64, sent: Int64) -> [TrafficBucket] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return [] }
        var cursor = start.timeIntervalSince1970
        let finish = end.timeIntervalSince1970
        var result: [TrafficBucket] = []
        var assignedDown: Int64 = 0, assignedUp: Int64 = 0
        while cursor < finish {
            let minute = floor(cursor / 60) * 60
            let stop = min(minute + 60, finish)
            let cumulative = (stop - start.timeIntervalSince1970) / duration
            let down = stop == finish ? received : Int64((Double(received) * cumulative).rounded(.down))
            let up = stop == finish ? sent : Int64((Double(sent) * cumulative).rounded(.down))
            result.append(TrafficBucket(start: Date(timeIntervalSince1970: minute),
                                        received: down - assignedDown, sent: up - assignedUp,
                                        coveredSeconds: stop - cursor))
            assignedDown = down; assignedUp = up; cursor = stop
        }
        return result
    }
}

public enum HistoryGranularity: String, CaseIterable, Identifiable {
    case minute, hour, day
    public var id: String { rawValue }
    public var title: String {
        switch self { case .minute: return "按分钟"; case .hour: return "按小时"; case .day: return "按天" }
    }
    public var component: Calendar.Component {
        switch self { case .minute: return .minute; case .hour: return .hour; case .day: return .day }
    }
    public var rangeComponent: Calendar.Component {
        switch self { case .minute: return .hour; case .hour: return .day; case .day: return .month }
    }
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: rangeComponent, for: date)!
    }
}

public enum TrafficFormat {
    public static func bytes(_ bytes: Double) -> String {
        let value = max(0, bytes)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = value, index = 0
        while scaled >= 1000 && index < units.count - 1 { scaled /= 1000; index += 1 }
        let digits = index == 0 ? 0 : (scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2))
        return String(format: "%.*f %@", digits, scaled, units[index])
    }
    public static func speed(_ bytes: Double) -> String { self.bytes(bytes) + "/s" }
    public static func coverage(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f 秒", seconds) }
        if seconds < 3600 { return String(format: "%.1f 分钟", seconds / 60) }
        return String(format: "%.1f 小时", seconds / 3600)
    }
}
