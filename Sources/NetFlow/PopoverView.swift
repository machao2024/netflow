import AppKit
import SwiftUI
import NetFlowCore
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var model: MonitorModel
    @State private var settings = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 12) {
            if settings { settingsView } else { dashboard }
        }
        .padding(16).frame(width: 400, height: 684, alignment: .top)
        .background(Theme.background(scheme))
        .alert("NetFlow", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var dashboard: some View {
        Group {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path").foregroundStyle(Theme.blue).font(.system(size: 18, weight: .semibold))
                Text("NetFlow").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.hasReading ? Theme.green : .orange).frame(width: 5, height: 5)
                    Text(model.statusText).font(.system(size: 10, weight: .semibold))
                }.foregroundStyle(model.hasReading ? Theme.green : .orange)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background((model.hasReading ? Theme.green : .orange).opacity(0.10), in: Capsule())
            }.padding(.bottom, 1)
            HStack(spacing: 6) {
                Image(systemName: "network").foregroundStyle(Theme.blue)
                Text(model.interfaceText).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("每秒采样").foregroundStyle(.tertiary)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                SpeedCard(title: "实时下行", symbol: "arrow.down", speed: model.download, samples: model.downloadHistory, color: Theme.green, available: model.hasReading)
                SpeedCard(title: "实时上行", symbol: "arrow.up", speed: model.upload, samples: model.uploadHistory, color: Theme.blue, available: model.hasReading)
            }
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label("今日流量", systemImage: "chart.bar.fill").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(Date(), format: .dateTime.month().day()).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(TrafficFormat.bytes(Double(model.today.total)))
                        .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                    HStack {
                        Label(TrafficFormat.bytes(Double(model.today.received)), systemImage: "arrow.down").foregroundStyle(Theme.green)
                        Spacer()
                        Label(TrafficFormat.bytes(Double(model.today.sent)), systemImage: "arrow.up").foregroundStyle(Theme.blue)
                    }.font(.system(size: 11, weight: .medium)).monospacedDigit()
                    GeometryReader { geo in
                        let ratio = model.today.total > 0 ? Double(model.today.received) / Double(model.today.total) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(model.today.total > 0 ? Theme.blue : .primary.opacity(0.08))
                            Capsule().fill(Theme.green).frame(width: geo.size.width * ratio)
                        }
                    }.frame(height: 4)
                    Divider().opacity(0.45)
                    HStack {
                        summary("本小时", value: model.thisHour.total, symbol: "clock", color: .orange)
                        Divider().frame(height: 28).padding(.horizontal, 8)
                        summary("本月累计", value: model.thisMonth.total, symbol: "calendar", color: Theme.purple)
                    }
                }
            }
            Card {
                VStack(spacing: 9) {
                    HStack {
                        Label("最近记录", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker("最近记录统计粒度", selection: $model.recentGranularity) {
                            Text("分钟").tag(HistoryGranularity.minute)
                            Text("小时").tag(HistoryGranularity.hour)
                            Text("天").tag(HistoryGranularity.day)
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.mini).frame(width: 156)
                    }.padding(.bottom, 2)
                    HStack {
                        Text("时间").frame(maxWidth: .infinity, alignment: .leading)
                        Text("下行").foregroundStyle(Theme.green).frame(width: 87, alignment: .trailing)
                        Text("上行").foregroundStyle(Theme.blue).frame(width: 87, alignment: .trailing)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(model.recent) { row in
                        HStack(spacing: 6) {
                            HStack(spacing: 5) {
                                Text(recentTimeLabel(row.start))
                                    .help(row.start.formatted(date: .complete, time: .shortened))
                                if Calendar.current.isDate(row.start, equalTo: Date(), toGranularity: model.recentGranularity.component) {
                                    Circle().fill(Theme.green).frame(width: 4, height: 4).help("当前时段，持续累计")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.hasSamples ? TrafficFormat.bytes(Double(row.received)) : "—").frame(width: 87, alignment: .trailing)
                            Text(row.hasSamples ? TrafficFormat.bytes(Double(row.sent)) : "—").frame(width: 87, alignment: .trailing)
                        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(row.hasSamples ? .primary : .tertiary)
                    }
                }
            }
            if let error = model.storageError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                    Text("本地记录 · 今日已监控 \(TrafficFormat.coverage(model.today.coveredSeconds))")
                    Spacer()
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { model.onHistory?() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chart.xyaxis.line").foregroundStyle(Theme.blue)
                        Text("查看全部记录").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 11).frame(height: 34)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                IconButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "继续监控" : "暂停监控") { model.togglePause() }
                IconButton(symbol: "gearshape", help: "设置") { settings = true }
                IconButton(symbol: "power", help: "退出 NetFlow", color: .red) { NSApp.terminate(nil) }
            }
        }
    }
    private func recentTimeLabel(_ date: Date) -> String {
        switch model.recentGranularity {
        case .minute: return date.formatted(.dateTime.hour().minute())
        case .hour: return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        case .day: return date.formatted(.dateTime.month().day())
        }
    }
    private func summary(_ label: String, value: Int64, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(TrafficFormat.bytes(Double(value))).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var settingsView: some View {
        Group {
            HStack {
                IconButton(symbol: "chevron.left", help: "返回监控") { settings = false }
                Text("偏好设置").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Card {
                VStack(alignment: .leading, spacing: 17) {
                    Text("显示").font(.system(size: 12, weight: .semibold))
                    Picker("菜单栏", selection: $model.menuMode) {
                        Text("实时上下行").tag("speeds")
                        Text("今日用量").tag("today")
                        Text("仅图标").tag("icon")
                    }
                    Picker("外观", selection: $model.appearance) {
                        Text("深色").tag("dark"); Text("浅色").tag("light"); Text("跟随系统").tag("system")
                    }
                }.font(.system(size: 12))
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("监控").font(.system(size: 12, weight: .semibold))
                    Picker("网络接口", selection: $model.selectedInterface) {
                        Text("自动 · 所有物理网卡").tag("auto")
                        ForEach(model.interfaces) { item in Text(item.label).tag(item.name) }
                        if model.selectedInterface != "auto" && !model.interfaces.contains(where: { $0.name == model.selectedInterface }) {
                            Text("\(model.selectedInterface)（未连接）").tag(model.selectedInterface)
                        }
                    }
                    Text("自动模式汇总 Wi-Fi、有线和 USB 网络（en*），排除 VPN、回环和 AirDrop 接口。切换接口后从新的基线开始，历史记录保留。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                    if model.loginNeedsApproval {
                        Button("在系统设置中允许登录启动") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 11))
                    }
                }.font(.system(size: 12))
            }
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    Label("数据与统计口径", systemImage: "internaldrive").font(.system(size: 12, weight: .semibold))
                    Text("每秒读取速率，按自然分钟累计；小时和每日按本地时区汇总。记录长期保存在这台 Mac，可在历史窗口导出 CSV。")
                    Text("包含局域网流量与协议开销，可能与运营商账单不同。仅记录应用运行且未暂停的时段；“—”表示没有采样记录。单位采用 1 KB = 1,000 B。")
                    Button("打开数据文件夹") { NSWorkspace.shared.open(model.dataDirectory) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("NetFlow 1.0 · Apple Silicon · macOS 13+").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
