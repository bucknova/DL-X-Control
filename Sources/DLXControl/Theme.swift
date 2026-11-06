import Charts
import DLXCore
import SwiftUI

enum Theme {
    static let primary = Color(hex: 0xF3F5F7)
    static let secondary = Color(hex: 0xC9D0D8)
    static let paneFill = Color(red: 10 / 255, green: 14 / 255, blue: 19 / 255).opacity(0.5)
    static let paneStroke = Color.white.opacity(0.075)
    static let grid = Color.white.opacity(0.1)

    // Series colors from the validated dark chart palette, one per measure.
    static let voltage = Color(hex: 0x3987E5)
    static let current = Color(hex: 0xD95926)
    static let power = Color(hex: 0x199E70)
    static let temperature = Color(hex: 0xC98500)
    static let comparison = [Color(hex: 0x3987E5), Color(hex: 0xD95926), Color(hex: 0x199E70)]

    static let loadOn = Color(hex: 0xFFB340)
    static let good = Color(hex: 0x5FE08A)
    static let warn = Color(hex: 0xFFD27A)
    static let critical = Color(hex: 0xFF9E96)
    static let cutoff = Color(hex: 0xFF8A80)

    @ViewBuilder static var wallpaper: some View {
        ZStack {
            Color(hex: 0x0D1218)
            RadialGradient(colors: [Color(hex: 0x2F6F86), .clear], center: .init(x: 0.08, y: 0.12), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [Color(hex: 0x8A4B23), .clear], center: .init(x: 0.92, y: 0.88), startRadius: 0, endRadius: 600)
            RadialGradient(colors: [Color(hex: 0x343A79), .clear], center: .init(x: 0.7, y: 0.08), startRadius: 0, endRadius: 540)
            Color(red: 14 / 255, green: 18 / 255, blue: 24 / 255).opacity(0.42)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct Pane: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(Theme.paneFill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.paneStroke))
    }
}

extension View {
    func pane(radius: CGFloat = 16) -> some View { modifier(Pane(radius: radius)) }
}

func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

func formatAh(_ ah: Double) -> String {
    ah < 1 ? String(format: "%.1f mAh", ah * 1000) : String(format: "%.2f Ah", ah)
}

func formatWh(_ wh: Double) -> String {
    wh < 1 ? String(format: "%.1f mWh", wh * 1000) : String(format: "%.1f Wh", wh)
}

/// With tenths, because several samples can land in the same second.
func formatPreciseClock(_ seconds: Double) -> String {
    let tenths = max(0, Int((seconds * 10).rounded()))
    let s = tenths / 10
    return String(format: "%d:%02d:%02d.%d", s / 3600, s / 60 % 60, s % 60, tenths % 10)
}

/// Ticks on round clock times, like every 30 minutes, rather than 16:40.
func timeTicks(_ domain: ClosedRange<Double>) -> [Double] {
    let span = domain.upperBound - domain.lowerBound
    let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400]
    let step = steps.first { span / $0 <= 7 } ?? 86400
    let first = (domain.lowerBound / step).rounded(.up) * step
    return Array(stride(from: first, through: domain.upperBound, by: step))
}

func formatShortClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600 ? String(format: "%d:%02d", s / 3600, s / 60 % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// One measure against time. Stacked with others on a shared time axis instead
/// of sharing a Y axis, so each keeps its own honest scale.
struct SeriesChart: View {
    let title: String
    let color: Color
    let samples: [Sample]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let value: (Sample) -> Double
    var rule: (value: Double, label: String)?
    var marks: [SessionMark] = []
    var showXAxis = false
    var hover: Binding<Double?>?

    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.t), yStart: .value("Base", yDomain.lowerBound), yEnd: .value(title, min(max(value(s), yDomain.lowerBound), yDomain.upperBound)))
                    .foregroundStyle(color.opacity(0.16))
                LineMark(x: .value("Time", s.t), y: .value(title, min(max(value(s), yDomain.lowerBound), yDomain.upperBound)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            if let last = samples.last {
                PointMark(x: .value("Time", last.t), y: .value(title, min(max(value(last), yDomain.lowerBound), yDomain.upperBound)))
                    .foregroundStyle(color)
                    .symbolSize(50)
            }
            if let rule, yDomain.contains(rule.value) {
                RuleMark(y: .value("Limit", rule.value))
                    .foregroundStyle(Theme.cutoff)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(rule.label).font(.caption2).foregroundStyle(Theme.critical)
                    }
            }
            ForEach(marks) { m in
                if xDomain.contains(m.t) {
                    RuleMark(x: .value("Mark", m.t))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            if let h = hover?.wrappedValue, xDomain.contains(h) {
                RuleMark(x: .value("Cursor", h)).foregroundStyle(.white.opacity(0.62)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if showXAxis {
                AxisMarks(values: timeTicks(xDomain)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(formatShortClock(d)).font(.caption2).foregroundStyle(Theme.secondary) } }
                }
            } else {
                AxisMarks(values: timeTicks(xDomain)) { _ in AxisGridLine().foregroundStyle(Theme.grid) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(axisText(d)).font(.caption2).foregroundStyle(Theme.secondary).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard let hover else { return }
                        switch phase {
                        case .active(let p):
                            guard let frame = proxy.plotFrame else { return }
                            hover.wrappedValue = proxy.value(atX: p.x - geo[frame].minX, as: Double.self)
                        case .ended: hover.wrappedValue = nil
                        }
                    }
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .topLeading) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.primary).padding(.leading, 46)
        }
        .accessibilityLabel(title)
    }

    private func axisText(_ d: Double) -> String {
        let span = yDomain.upperBound - yDomain.lowerBound
        return span < 2 ? String(format: "%.2f", d) : span < 20 ? String(format: "%.1f", d) : String(format: "%.0f", d)
    }
}

/// A pad around the data, or a sane default when there is nothing to scale to.
func niceDomain(_ values: [Double], minimumSpan: Double, floorZero: Bool = false, include: [Double] = []) -> ClosedRange<Double> {
    let all = values + include
    guard var lo = all.min(), var hi = all.max() else { return 0...minimumSpan }
    if hi - lo < minimumSpan {
        let mid = (hi + lo) / 2
        lo = mid - minimumSpan / 2
        hi = mid + minimumSpan / 2
    }
    let pad = (hi - lo) * 0.1
    lo -= pad; hi += pad
    if floorZero || lo < 0 { lo = 0 }
    return lo...max(hi, lo + 0.001)
}

/// Value field with stepper buttons. Sends only on Return or a button press,
/// so typing "12" cannot send 1 A and then 12 A to a live load.
struct SetpointField: View {
    let label: String
    let unit: String
    let value: Double
    let step: Double
    let decimals: Int
    var range: ClosedRange<Double> = 0...1_000_000
    var offText: String?
    var disabled = false
    let commit: (Double) -> Void

    @LocalState private var text = ""
    @FocusState private var focused: Bool

    private var display: String {
        if value == 0, let offText { return offText }
        return String(format: "%.\(decimals)f \(unit)", value)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Color(hex: 0xD5DBE2)).lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            Spacer(minLength: 2)
            TextField(label, text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .frame(width: 72)
                .focused($focused)
                .onSubmit { submit() }
                .onChange(of: focused) { _, f in text = f ? String(format: "%.\(decimals)f", value) : display }
            Button { nudge(-step) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                .buttonStyle(.glass).accessibilityLabel("Decrease \(label)")
            Button { nudge(step) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                .buttonStyle(.glass).accessibilityLabel("Increase \(label)")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 48)
        .pane(radius: 13)
        .disabled(disabled)
        .onAppear { text = display }
        .onChange(of: value) { _, _ in if !focused { text = display } }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func nudge(_ d: Double) {
        focused = false
        commit(clamp(value + d))
    }

    private func submit() {
        let cleaned = text.filter { "0123456789.".contains($0) }
        if let v = Double(cleaned) { commit(clamp(v)) }
        focused = false
        text = display
    }
}

/// SwiftUI's `@State` macro needs a compiler plugin that ships only with Xcode.
/// This wraps the same underlying storage, so the app builds with the Command
/// Line Tools alone and behaves the same way.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private var storage: SwiftUICore.State<Value>
    init(wrappedValue: Value) { storage = SwiftUICore.State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
