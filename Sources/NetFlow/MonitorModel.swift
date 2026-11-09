import AppKit
import Combine
import Foundation
import NetFlowCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class MonitorModel: ObservableObject {
    @Published var download: Double = 0
    @Published var upload: Double = 0
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
    @Published var interfaces: [NetworkInterface] = []
    @Published var activeInterfaces: [String] = []
    @Published var today = TrafficBucket(start: Date())
    @Published var thisHour = TrafficBucket(start: Date())
    @Published var thisMonth = TrafficBucket(start: Date())
    @Published var recent: [TrafficBucket] = []
    @Published var recentGranularity: HistoryGranularity {
        didSet {
            UserDefaults.standard.set(recentGranularity.rawValue, forKey: "recentGranularity")
            refreshSummaries()
        }
    }
    @Published var history: [TrafficBucket] = []
    @Published var granularity: HistoryGranularity = .hour { didSet { refreshHistory() } }
    @Published var anchor = Date() { didSet { refreshHistory() } }
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published var exportMessage: String?
    @Published var lastSample: Date?
    @Published var isPaused = false
    @Published var hasReading = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var selectedInterface: String {
        didSet {
            UserDefaults.standard.set(selectedInterface, forKey: "interface")
            accumulator.reset(); download = 0; upload = 0; hasReading = false
            downloadHistory = []; uploadHistory = []
        }
    }
    @Published var menuMode: String {
        didSet { UserDefaults.standard.set(menuMode, forKey: "menuMode") }
    }
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    let store: TrafficStore
    let dataDirectory: URL
    var historyVisible = false
    var onHistory: (() -> Void)?
    private var accumulator = TrafficAccumulator()
    private var pending: [Date: TrafficBucket] = [:]
    private var timer: Timer?
    private var ticks = 0
    private var observations: [NSObjectProtocol] = []
    private var sampleError: String?

    init(directory: URL, preview: Bool = false) throws {
        dataDirectory = directory
        selectedInterface = UserDefaults.standard.string(forKey: "interface") ?? "auto"
        menuMode = UserDefaults.standard.string(forKey: "menuMode") ?? "speeds"
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "dark"
        recentGranularity = HistoryGranularity(rawValue: UserDefaults.standard.string(forKey: "recentGranularity") ?? "") ?? .minute
        if !preview { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        store = try TrafficStore(path: preview ? ":memory:" : directory.appendingPathComponent("traffic.sqlite").path)
        interfaces = NetworkReader.interfaces()
        if preview { seedPreview(); return }
        refreshSummaries()
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleep() }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
        startTimer()
    }

    var statusText: String {
        if isPaused { return "已暂停" }
        if sampleError != nil { return "采样异常" }
        if activeInterfaces.isEmpty { return "等待网络" }
        return hasReading ? "监控中" : "正在采样"
    }
    var interfaceText: String {
        if selectedInterface == "auto" {
            return activeInterfaces.isEmpty ? "自动 · 物理网卡" : "自动 · " + activeInterfaces.joined(separator: " + ")
        }
        return interfaces.first { $0.name == selectedInterface }?.label ?? selectedInterface
    }
    var range: DateInterval { granularity.interval(containing: anchor) }
    var historyTotal: TrafficBucket {
        history.reduce(TrafficBucket(start: range.start)) { partial, row in
            var total = partial; total.received += row.received; total.sent += row.sent; total.coveredSeconds += row.coveredSeconds
            return total
        }
    }
    var canGoForward: Bool { range.end <= Date() }

    private func startTimer() {
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func tick() {
        guard !isPaused else { return }
        do {
            let snapshot = try NetworkReader.read(interface: selectedInterface)
            activeInterfaces = snapshot.interfaces.filter(\.isUp).map(\.name)
            sampleError = nil
            if let sample = accumulator.consume(snapshot) {
                download = sample.receivedPerSecond; upload = sample.sentPerSecond; hasReading = true
                for item in sample.buckets {
                    var existing = pending[item.start] ?? TrafficBucket(start: item.start)
                    existing.received += item.received; existing.sent += item.sent; existing.coveredSeconds += item.coveredSeconds
                    pending[item.start] = existing
                }
                lastSample = snapshot.date
            } else {
                download = 0; upload = 0; hasReading = false
            }
            downloadHistory.append(download); uploadHistory.append(upload)
            if downloadHistory.count > 60 { downloadHistory.removeFirst(downloadHistory.count - 60) }
            if uploadHistory.count > 60 { uploadHistory.removeFirst(uploadHistory.count - 60) }
            ticks += 1
            if ticks % 10 == 0 { flush() }
            if ticks % 3 == 0 { refreshSummaries() }
            if ticks % 10 == 0 && historyVisible { refreshHistory() }
            if ticks % 30 == 0 { interfaces = NetworkReader.interfaces() }
        } catch {
            sampleError = "无法读取网卡：\(error.localizedDescription)"
            errorMessage = sampleError
            download = 0; upload = 0; hasReading = false; activeInterfaces = []; accumulator.reset()
        }
    }
    func flush() {
        do {
            try store.merge(Array(pending.values))
            pending.removeAll(); storageError = nil
        } catch { storageError = "记录尚未保存：\(error.localizedDescription)" }
    }
    func prepareForQuit() {
        if !isPaused { tick() }
        flush()
    }
    func shutdown() {
        timer?.invalidate(); timer = nil; flush()
    }
    private func sleep() {
        if !isPaused { tick() }
        flush(); timer?.invalidate(); timer = nil; accumulator.reset()
        download = 0; upload = 0; hasReading = false
    }
    private func wake() {
        accumulator.reset(); interfaces = NetworkReader.interfaces()
        if timer == nil { startTimer() }
    }
    func togglePause() {
        if !isPaused { tick(); flush() }
        isPaused.toggle(); accumulator.reset(); download = 0; upload = 0; hasReading = false
        downloadHistory = []; uploadHistory = []
        if !isPaused { tick() }
        refreshSummaries()
    }
    private func total(in interval: DateInterval) throws -> TrafficBucket {
        var total = try store.total(in: interval)
        for bucket in pending.values where bucket.start >= interval.start && bucket.start < interval.end {
            total.received += bucket.received; total.sent += bucket.sent; total.coveredSeconds += bucket.coveredSeconds
        }
        return total
    }
    private func rows(in interval: DateInterval) throws -> [TrafficBucket] {
        var rows = Dictionary(uniqueKeysWithValues: try store.read(in: interval).map { ($0.start, $0) })
        for bucket in pending.values where bucket.start >= interval.start && bucket.start < interval.end {
            var merged = rows[bucket.start] ?? TrafficBucket(start: bucket.start)
            merged.received += bucket.received; merged.sent += bucket.sent; merged.coveredSeconds += bucket.coveredSeconds
            rows[bucket.start] = merged
        }
        return rows.values.sorted { $0.start < $1.start }
    }
    func refreshSummaries() {
        let now = Date(), calendar = Calendar.current
        do {
            today = try total(in: calendar.dateInterval(of: .day, for: now)!)
            thisHour = try total(in: calendar.dateInterval(of: .hour, for: now)!)
            thisMonth = try total(in: calendar.dateInterval(of: .month, for: now)!)
            let current = calendar.dateInterval(of: recentGranularity.component, for: now)!
            let start = calendar.date(byAdding: recentGranularity.component, value: -4, to: current.start)!
            let interval = DateInterval(start: start, end: current.end)
            recent = TrafficStore.aggregate(try rows(in: interval), by: recentGranularity, in: interval).reversed()
        } catch { storageError = "无法读取记录：\(error.localizedDescription)" }
    }
    func refreshHistory() {
        do { history = TrafficStore.aggregate(try rows(in: range), by: granularity, in: range) }
        catch { storageError = "无法读取历史：\(error.localizedDescription)" }
    }
    func navigate(_ offset: Int) {
        if let date = Calendar.current.date(byAdding: granularity.rangeComponent, value: offset, to: range.start) { anchor = date }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = "登录启动设置失败：\(error.localizedDescription)" }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func exportHistory() {
        refreshHistory()
        let output = TrafficStore.csv(history, granularity: granularity)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HH"
        panel.nameFieldStringValue = "NetFlow-\(granularity.rawValue)-\(formatter.string(from: range.start)).csv"
        panel.title = "导出当前时段的流量记录"
        if panel.runModal() == .OK, let url = panel.url {
            do { try output.write(to: url, atomically: true, encoding: .utf8); exportMessage = "已导出 \(url.lastPathComponent)" }
            catch { errorMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
    private func seedPreview() {
        download = 2_430_000; upload = 186_000; activeInterfaces = ["en0"]; hasReading = true; lastSample = Date()
        downloadHistory = (0..<60).map { i -> Double in
            let base = Double(300_000 + (i * 73_123) % 1_800_000)
            let wave = 0.6 + sin(Double(i) / 5.0) * 0.4
            return base * wave
        }
        uploadHistory = (0..<60).map { Double(30_000 + ($0 * 13_123) % 200_000) }
        let now = Date(), calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let minutes = max(1, Int(now.timeIntervalSince(day) / 60))
        let demo = (0...minutes).map { i -> TrafficBucket in
            let start = day.addingTimeInterval(Double(i) * 60.0)
            let down = Int64(1_000_000 + (i * 1_351_327) % 20_000_000)
            let up = Int64(100_000 + (i * 57_313) % 2_000_000)
            return TrafficBucket(start: start, received: down, sent: up, coveredSeconds: 60)
        }
        try? store.merge(demo)
        refreshSummaries(); refreshHistory()
    }
}
