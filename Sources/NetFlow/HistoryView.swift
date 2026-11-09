import SwiftUI
import Charts
import NetFlowCore

struct HistoryView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredDate: Date?
    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = model.granularity == .day ? "MM月dd日" : "HH:mm"
        return f
    }
    private var rangeTitle: String {
        let f = DateFormatter()
        switch model.granularity {
        case .minute: f.dateFormat = "yyyy年MM月dd日 HH:00"
        case .hour: f.dateFormat = "yyyy年MM月dd日"
        case .day: f.dateFormat = "yyyy年MM月"
        }
        return f.string(from: model.range.start)
    }
    private var selectedRow: TrafficBucket? {
        guard let date = hoveredDate else { return nil }
        return model.history.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path").foregroundStyle(Theme.blue)
                        Text("流量记录").font(.system(size: 24, weight: .bold))
                    }
                    Text("查看分钟、小时和每日用量").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.exportHistory() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                    .controlSize(.large)
            }
            HStack(spacing: 12) {
                Picker("统计粒度", selection: $model.granularity) {
                    ForEach(HistoryGranularity.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                DatePicker("日期", selection: $model.anchor, in: ...Date(), displayedComponents: model.granularity == .minute ? [.date, .hourAndMinute] : [.date])
                    .labelsHidden().datePickerStyle(.field).fixedSize()
                Button("现在") { model.anchor = Date() }
            }
            HStack(spacing: 12) {
                metric("总用量", value: model.historyTotal.total, color: .primary)
                metric("下行流量", value: model.historyTotal.received, color: Theme.green)
                metric("上行流量", value: model.historyTotal.sent, color: Theme.blue)
            }
            Card {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        IconButton(symbol: "chevron.left", help: "上一时段") { model.navigate(-1) }
                        Text(rangeTitle).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        IconButton(symbol: "chevron.right", help: "下一时段") { model.navigate(1) }.disabled(!model.canGoForward)
                        Spacer()
                        if let row = selectedRow {
                            Text("\(formatter.string(from: row.start))  ↓ \(TrafficFormat.bytes(Double(row.received)))  ↑ \(TrafficFormat.bytes(Double(row.sent)))\(row.hasSamples ? "" : " · 未记录")")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        } else {
                            Label("下行", systemImage: "circle.fill").foregroundStyle(Theme.green)
                            Label("上行", systemImage: "circle.fill").foregroundStyle(Theme.blue)
                        }
                    }.font(.system(size: 10))
                    chart.frame(height: 155)
                }
            }
            HStack {
                Text("明细").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("已监控 \(TrafficFormat.coverage(model.historyTotal.coveredSeconds)) · 未记录时段不计为零流量")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            table
            HStack {
                Image(systemName: "internaldrive")
                Text(model.storageError ?? model.exportMessage ?? "数据仅保存在本机 · 按当前本地时区汇总 · 当前时段持续累计")
                Spacer()
                Text("1 KB = 1,000 B")
            }.font(.system(size: 10)).foregroundStyle(model.storageError == nil ? Color.secondary : Color.orange)
        }.padding(24).frame(minWidth: 820, minHeight: 720)
            .background(Theme.background(scheme))
            .onAppear { model.historyVisible = true; model.refreshHistory() }
            .onDisappear { model.historyVisible = false }
            .alert("NetFlow", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
    private func metric(_ title: String, value: Int64, color: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(TrafficFormat.bytes(Double(value))).font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(color)
            }
        }
    }
    private var chart: some View {
        Chart {
            ForEach(model.history) { row in
                if row.hasSamples {
                    BarMark(x: .value("时间", row.start, unit: model.granularity.component), y: .value("下行", Double(row.received)))
                        .foregroundStyle(Theme.green)
                    BarMark(x: .value("时间", row.start, unit: model.granularity.component), y: .value("上行", Double(row.sent)))
                        .foregroundStyle(Theme.blue)
                }
            }
            if let row = selectedRow {
                RuleMark(x: .value("选中时间", row.start)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartXScale(domain: model.range.start...model.range.end)
        .chartYScale(domain: 0...max(1000, Double(model.history.map(\.total).max() ?? 0) * 1.15))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.07))
                AxisValueLabel { if let bytes = value.as(Double.self) { Text(TrafficFormat.bytes(bytes)).font(.system(size: 9)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisValueLabel { if let date = value.as(Date.self) { Text(formatter.string(from: date)).font(.system(size: 9)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                            hoveredDate = proxy.value(atX: x, as: Date.self)
                        case .ended: hoveredDate = nil
                        }
                    }
            }
        }
        .overlay {
            if !model.history.contains(where: \.hasSamples) {
                VStack(spacing: 5) {
                    Image(systemName: "chart.bar.xaxis").font(.title2)
                    Text("这个时段还没有记录").font(.system(size: 12, weight: .medium))
                    Text("保持 NetFlow 运行，流量会自动记录在这里").font(.system(size: 10))
                }.foregroundStyle(.secondary).padding(16).background(Theme.card(scheme).opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                tableCell("时间", width: 140, leading: true)
                tableCell("下行", color: Theme.green)
                tableCell("上行", color: Theme.blue)
                tableCell("总流量")
                tableCell("已监控 / 状态", width: 150)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 11).background(.primary.opacity(0.035))
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.history.filter { $0.start <= Date() }.reversed())) { row in
                        HStack {
                            tableCell(formatter.string(from: row.start), width: 140, leading: true)
                            tableCell(row.hasSamples ? TrafficFormat.bytes(Double(row.received)) : "—")
                            tableCell(row.hasSamples ? TrafficFormat.bytes(Double(row.sent)) : "—")
                            tableCell(row.hasSamples ? TrafficFormat.bytes(Double(row.total)) : "—")
                            tableCell(row.hasSamples ? TrafficFormat.coverage(row.coveredSeconds) : (row.start > Date() ? "尚未开始" : "未记录"), width: 150,
                                      color: row.hasSamples ? .secondary : .secondary.opacity(0.5))
                        }.font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        Divider().opacity(0.25)
                    }
                }
            }
        }.frame(minHeight: 145, maxHeight: .infinity)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.05)))
    }
    private func tableCell(_ text: String, width: CGFloat? = nil, leading: Bool = false, color: Color = .primary) -> some View {
        Text(text).foregroundStyle(color).frame(maxWidth: width == nil ? .infinity : nil, alignment: leading ? .leading : .trailing)
            .frame(width: width, alignment: leading ? .leading : .trailing).lineLimit(1)
    }
}
