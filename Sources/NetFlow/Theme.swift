import SwiftUI
import NetFlowCore

// Green / blue direction cues follow the user's F50 reference.
enum Theme {
    static let green = Color(red: 0.20, green: 0.79, blue: 0.56)
    static let blue = Color(red: 0.27, green: 0.57, blue: 1.0)
    static let purple = Color(red: 0.65, green: 0.51, blue: 0.95)
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.065, green: 0.082, blue: 0.11) : Color(red: 0.94, green: 0.95, blue: 0.97)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.13, blue: 0.17) : .white
    }
}
struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055)))
    }
}
struct IconButton: View {
    let symbol: String
    let help: String
    var color: Color = .secondary
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(color).frame(width: 36, height: 34)
                .background(.primary.opacity(hovered ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).onHover { hovered = $0 }.help(help).accessibilityLabel(help)
    }
}
struct Sparkline: View {
    let samples: [Double]
    let color: Color
    var body: some View {
        Canvas { context, size in
            let values = samples.count > 1 ? samples : [0, 0]
            let scale = max(1000, values.max() ?? 1000)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: size.height - 2 - (size.height - 5) * CGFloat(value / scale))
            }
            var line = Path(); line.addLines(points)
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.27), color.opacity(0.015)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
struct SpeedCard: View {
    let title: String
    let symbol: String
    let speed: Double
    let samples: [Double]
    let color: Color
    let available: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                    .frame(width: 25, height: 25).background(color.opacity(0.13), in: Circle())
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.padding(.horizontal, 13).padding(.top, 12)
            Text(available ? TrafficFormat.speed(speed) : "—")
                .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 13)
            Sparkline(samples: samples, color: color).frame(height: 35)
        }
        .frame(maxWidth: .infinity).background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.055)))
        .accessibilityElement(children: .combine)
    }
}
struct AppearanceView<Content: View>: View {
    @ObservedObject var model: MonitorModel
    @ViewBuilder var content: Content
    var body: some View {
        content.preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "light" ? .light : .dark)
    }
}
