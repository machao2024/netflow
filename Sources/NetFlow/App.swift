import AppKit
import Combine
import SwiftUI
import NetFlowCore
import Darwin

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: MonitorModel!
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var lockFD: Int32 = -1

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") { runProbe(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Self.argument("--render-preview") {
            do { try renderPreview(to: path) }
            catch { fputs("Preview: \(error)\n", stderr) }
            NSApp.terminate(nil); return
        }
        do {
            let directory: URL
            if let path = Self.argument("--data-dir") { directory = URL(fileURLWithPath: path) }
            else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("NetFlow", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else { throw StoreError(message: "无法创建运行锁") }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                // A second process must never add the same system counters to the database.
                if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.NetFlow").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                    other.activate(options: [.activateIgnoringOtherApps])
                }
                NSApp.terminate(nil); return
            }
            model = try MonitorModel(directory: directory)
            model.onHistory = { [weak self] in self?.showHistory() }
            configureMenu()
            configurePopover()
            configureStatusItem()
            model.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main).sink { [weak self] in self?.updateStatus() }.store(in: &cancellables)
            updateStatus()
            let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            if firstLaunch || CommandLine.arguments.contains("--show") { togglePopover(nil) }
        } catch {
            let alert = NSAlert(); alert.messageText = "NetFlow 无法启动"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func configurePopover() {
        popover = NSPopover(); popover.behavior = .transient; popover.animates = true
        let controller = NSHostingController(rootView: AppearanceView(model: model) { PopoverView(model: model) })
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 400, height: 684)
    }
    private func configureMenu() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem(); menuBar.addItem(appItem)
        let applicationMenu = NSMenu(title: "NetFlow")
        let history = applicationMenu.addItem(withTitle: "查看全部记录", action: #selector(openHistory), keyEquivalent: "0")
        history.target = self
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出 NetFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appItem.submenu = applicationMenu
        let editItem = NSMenuItem(); editItem.title = "编辑"; menuBar.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem(); windowItem.title = "窗口"; menuBar.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = menuBar
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemWidth(for: model.menuMode))
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "NetFlow 网络监控")
        button.image?.isTemplate = true; button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.alignment = .left
        button.target = self; button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    private func statusItemWidth(for mode: String) -> CGFloat {
        if mode == "icon" { return NSStatusItem.squareLength }
        // Reserve space for the display mode, never for the current reading.
        // A variable-length item moves its popover whenever digits or units change.
        let widestTitle = mode == "today" ? " 999.9 MB" : " ↓ 999.9 MB/s  ↑ 999.9 MB/s"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return ceil((widestTitle as NSString).size(withAttributes: [.font: font]).width) + 40
    }
    private func updateStatus() {
        guard let button = statusItem?.button, let model else { return }
        let width = statusItemWidth(for: model.menuMode)
        if statusItem.length != width { statusItem.length = width }
        switch model.menuMode {
        case "icon": button.title = ""
        case "today": button.title = " " + TrafficFormat.bytes(Double(model.today.total))
        default:
            if model.isPaused { button.title = " 已暂停" }
            else if !model.hasReading { button.title = " ↓ —  ↑ —" }
            else { button.title = " ↓ \(TrafficFormat.speed(model.download))  ↑ \(TrafficFormat.speed(model.upload))" }
        }
        button.toolTip = "NetFlow · \(model.statusText)\n下行：\(TrafficFormat.speed(model.download))\n上行：\(TrafficFormat.speed(model.upload))\n今日：\(TrafficFormat.bytes(Double(model.today.total)))"
        button.setAccessibilityLabel("NetFlow，\(model.statusText)，下行 \(TrafficFormat.speed(model.download))，上行 \(TrafficFormat.speed(model.upload))")
    }
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "查看全部记录", action: #selector(openHistory), keyEquivalent: "")
            menu.addItem(withTitle: model.isPaused ? "继续监控" : "暂停监控", action: #selector(pauseMonitoring), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 NetFlow", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil; return
        }
        if popover.isShown { popover.performClose(sender) }
        else {
            model.refreshSummaries()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func openHistory() { showHistory() }
    @objc private func pauseMonitoring() { model.togglePause() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func showHistory() {
        popover.performClose(nil)
        model.historyVisible = true; model.refreshHistory()
        if historyWindow == nil {
            let controller = NSHostingController(rootView: AppearanceView(model: model) { HistoryView(model: model) })
            let window = NSWindow(contentViewController: controller)
            window.title = "NetFlow · 流量记录"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 760)); window.minSize = NSSize(width: 840, height: 740)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.center(); historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model?.historyVisible = false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model != nil { togglePopover(nil) }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareForQuit()
        if let failure = model?.storageError {
            let alert = NSAlert(); alert.messageText = "部分记录还没有保存"; alert.informativeText = failure
            alert.addButton(withTitle: "重试保存"); alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn {
                model?.flush()
                if model?.storageError != nil { return .terminateCancel }
            }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    private func renderPreview(to path: String) throws {
        let model = try MonitorModel(directory: URL(fileURLWithPath: "/tmp"), preview: true)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try renderNative(PopoverView(model: model), size: NSSize(width: 400, height: 684), to: directory.appendingPathComponent("panel.png"))
        try renderNative(HistoryView(model: model), size: NSSize(width: 940, height: 760), to: directory.appendingPathComponent("history.png"))
        print("Preview rendered to \(path) (demonstration data)")
    }
    private func renderNative<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        // ImageRenderer omits AppKit-backed pickers, buttons and scrolling content.
        let view = NSHostingView(rootView: content.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; window.center(); window.orderFront(nil)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw StoreError(message: "无法渲染预览") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw StoreError(message: "无法生成 PNG") }
        try data.write(to: url); window.orderOut(nil)
    }
    private static func runProbe() {
        do {
            var accumulator = TrafficAccumulator()
            let first = try NetworkReader.read()
            print("Interfaces: " + first.interfaces.map { "\($0.name)(up=\($0.isUp), rx=\($0.received), tx=\($0.sent))" }.joined(separator: ", "))
            _ = accumulator.consume(first)
            let seconds = max(2, min(120, Int(argument("--seconds") ?? "3") ?? 3))
            var buckets: [TrafficBucket] = []
            for _ in 0..<seconds {
                Thread.sleep(forTimeInterval: 1)
                if let sample = accumulator.consume(try NetworkReader.read()) {
                    buckets.append(contentsOf: sample.buckets)
                    print("↓ \(TrafficFormat.speed(sample.receivedPerSecond)) ↑ \(TrafficFormat.speed(sample.sentPerSecond))")
                }
            }
            let directory = URL(fileURLWithPath: argument("--data-dir") ?? NSTemporaryDirectory()).appendingPathComponent("NetFlowProbe")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try TrafficStore(path: directory.appendingPathComponent("probe-\(UUID().uuidString).sqlite").path)
            try store.merge(buckets)
            let total = try store.total(in: DateInterval(start: first.date.addingTimeInterval(-60), end: Date().addingTimeInterval(60)))
            print("Persisted ↓ \(total.received) bytes ↑ \(total.sent) bytes, coverage \(total.coveredSeconds)s; database: \(store.path)")
            guard total.coveredSeconds > 0 else { throw StoreError(message: "No active network interface sampled") }
        } catch { fputs("Probe failed: \(error)\n", stderr); exit(1) }
    }
}
