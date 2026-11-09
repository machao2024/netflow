import Foundation
import CSQLite

public struct StoreError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Access from a single serial executor. Each batch is committed atomically.
public final class TrafficStore {
    private var database: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(database); database = nil
            throw StoreError(message: message)
        }
        do {
            sqlite3_busy_timeout(database, 2000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS minutes (
                    minute INTEGER PRIMARY KEY,
                    received INTEGER NOT NULL CHECK(received >= 0),
                    sent INTEGER NOT NULL CHECK(sent >= 0),
                    covered REAL NOT NULL CHECK(covered >= 0)
                );
                PRAGMA user_version=1;
                """)
        } catch {
            sqlite3_close(database); database = nil; throw error
        }
    }
    deinit { sqlite3_close(database) }

    private func error() -> StoreError { StoreError(message: String(cString: sqlite3_errmsg(database))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw error() }
        return result
    }

    public func merge(_ buckets: [TrafficBucket]) throws {
        guard !buckets.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let query = try statement("""
                INSERT INTO minutes (minute, received, sent, covered) VALUES (?, ?, ?, ?)
                ON CONFLICT(minute) DO UPDATE SET
                received = received + excluded.received,
                sent = sent + excluded.sent,
                covered = MIN(60.0, covered + excluded.covered)
                """)
            defer { sqlite3_finalize(query) }
            for bucket in buckets {
                sqlite3_reset(query)
                sqlite3_bind_int64(query, 1, Int64(bucket.start.timeIntervalSince1970))
                sqlite3_bind_int64(query, 2, bucket.received)
                sqlite3_bind_int64(query, 3, bucket.sent)
                sqlite3_bind_double(query, 4, bucket.coveredSeconds)
                guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK"); throw error
        }
    }

    public func read(in range: DateInterval) throws -> [TrafficBucket] {
        let query = try statement("SELECT minute, received, sent, covered FROM minutes WHERE minute >= ? AND minute < ? ORDER BY minute")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(range.start.timeIntervalSince1970))
        sqlite3_bind_int64(query, 2, Int64(range.end.timeIntervalSince1970))
        var result: [TrafficBucket] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            result.append(TrafficBucket(start: Date(timeIntervalSince1970: Double(sqlite3_column_int64(query, 0))),
                received: sqlite3_column_int64(query, 1), sent: sqlite3_column_int64(query, 2),
                coveredSeconds: sqlite3_column_double(query, 3)))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw error() }
        return result
    }

    public func total(in range: DateInterval) throws -> TrafficBucket {
        let query = try statement("SELECT COALESCE(SUM(received),0), COALESCE(SUM(sent),0), COALESCE(SUM(covered),0) FROM minutes WHERE minute >= ? AND minute < ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(range.start.timeIntervalSince1970))
        sqlite3_bind_int64(query, 2, Int64(range.end.timeIntervalSince1970))
        guard sqlite3_step(query) == SQLITE_ROW else { throw error() }
        return TrafficBucket(start: range.start, received: sqlite3_column_int64(query, 0),
                             sent: sqlite3_column_int64(query, 1), coveredSeconds: sqlite3_column_double(query, 2))
    }

    public static func aggregate(_ rows: [TrafficBucket], by granularity: HistoryGranularity,
                                 in range: DateInterval, calendar: Calendar = .current) -> [TrafficBucket] {
        var groups: [Date: TrafficBucket] = [:]
        for row in rows where row.start >= range.start && row.start < range.end {
            let start = calendar.dateInterval(of: granularity.component, for: row.start)!.start
            var bucket = groups[start] ?? TrafficBucket(start: start)
            bucket.received += row.received; bucket.sent += row.sent; bucket.coveredSeconds += row.coveredSeconds
            groups[start] = bucket
        }
        var cursor = range.start, result: [TrafficBucket] = []
        while cursor < range.end {
            result.append(groups[cursor] ?? TrafficBucket(start: cursor))
            guard let next = calendar.date(byAdding: granularity.component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    public static func csv(_ rows: [TrafficBucket], granularity: HistoryGranularity) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var lines = ["时间,粒度,下行字节,上行字节,总字节,已监控秒数,记录状态"]
        for row in rows {
            lines.append("\(formatter.string(from: row.start)),\(granularity.title),\(row.received),\(row.sent),\(row.total),\(String(format: "%.2f", row.coveredSeconds)),\(row.hasSamples ? "已记录" : "未记录")")
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
