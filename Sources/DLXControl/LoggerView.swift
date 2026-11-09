import AppKit
import Charts
import DLXCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 16)
            List(model.store.sessions, selection: $model.selectedSession) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).fontWeight(.semibold).lineLimit(1)
                    Text(meta(s)).font(.caption).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                }
                .tag(s.id)
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Delete session", role: .destructive) { model.store.delete(s.id) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear { selectNewestIfNew() }
            .onChange(of: model.store.sessions.first?.id) { _, _ in selectNewestIfNew() }
        }
    }

    /// A new recording opens automatically, even if it finished on another screen.
    /// Otherwise the session you chose stays selected.
    private func selectNewestIfNew() {
        guard let newest = model.store.sessions.first?.id, newest != model.newestSessionSeen else { return }
        model.newestSessionSeen = newest
        model.selectedSession = newest
    }

    private func meta(_ s: SessionMeta) -> String {
        let date = s.date.formatted(Calendar.current.isDateInToday(s.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
        if s.summary.capacityAh > 0 { return "\(date), " + formatAh(s.summary.capacityAh) }
        return "\(date), \(formatClock(s.summary.duration))"
    }
}

struct LoggerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.selectedSession, let meta = model.store.sessions.first(where: { $0.id == id }) {
                SessionDetail(meta: meta).id(meta.id)
            } else {
                ContentUnavailableView("No session selected", systemImage: "list.bullet.rectangle",
                                       description: Text("Sessions appear here after the load runs or you press Record."))
                    .navigationTitle("Logger")
            }
        }
    }
}

struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta
    @LocalState private var samples: [Sample] = []
    @LocalState private var compare: Set<UUID> = []
    @LocalState private var showCompare = false
    @LocalState private var hover: Double?
    @LocalState private var renaming = false
    @LocalState private var newName = ""

    private var chart: [Sample] { downsample(samples, limit: 600) }
    private var rate: Double { meta.summary.duration > 0 ? Double(samples.count) / meta.summary.duration : 0 }

    var body: some View {
        VStack(spacing: 10) {
            ScreenHeader(title: meta.name, subtitle: subtitle) {
                Button("Rename") { newName = meta.name; renaming = true }
                Button("Compare") { showCompare = true }
                    .popover(isPresented: $showCompare, arrowEdge: .bottom) { comparePicker }
                Button("Export CSV") { exportCSV() }
                Button("JSON") { exportJSON() }
                Button("PDF report") { exportPDF() }
            }
            SummaryRow(meta: meta, summary: SessionSummary(samples: samples, linkDrops: meta.summary.linkDrops))
            HStack(spacing: 10) {
                DischargeCurve(meta: meta, samples: chart, others: comparisons)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    miniChart("MOSFET temperature, °C", Theme.temperature, \.temperatureC, minSpan: 10)
                    miniChart("Power, W", Theme.power, \.power, minSpan: 5, zero: true)
                }
                .frame(width: 400)
            }
            .frame(height: 300)
            SampleTable(samples: samples, marks: meta.marks, rate: rate, hover: hover)
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { var m = meta; m.name = newName; model.store.save(m) }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: meta.id) { samples = model.store.samples(for: meta.id) }
    }

    private var subtitle: String {
        var s = meta.date.formatted(date: .abbreviated, time: .shortened)
        if let stop = meta.stop { s += ", " + stop.title.lowercased() }
        s += ", \(formatClock(meta.summary.duration))"
        return s
    }

    private var comparisons: [(SessionMeta, [Sample])] {
        compare.compactMap { id in
            guard let m = model.store.sessions.first(where: { $0.id == id }) else { return nil }
            return (m, downsample(model.store.samples(for: id), limit: 400))
        }.sorted { $0.0.date > $1.0.date }
    }

    private var comparePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare discharge curves").font(.headline)
            Text("Choose up to 2 other sessions.").foregroundStyle(Theme.secondary)
            ForEach(model.store.sessions.filter { $0.id != meta.id }) { s in
                Toggle(s.name, isOn: Binding(get: { compare.contains(s.id) }, set: { on in
                    if on { if compare.count < 2 { compare.insert(s.id) } } else { compare.remove(s.id) }
                }))
            }
            if model.store.sessions.count < 2 { Text("There are no other sessions yet.").foregroundStyle(Theme.secondary) }
        }
        .padding(14).frame(width: 280)
    }

    private func miniChart(_ title: String, _ color: Color, _ value: @escaping (Sample) -> Double, minSpan: Double, zero: Bool = false) -> some View {
        let c = chart
        let lo = c.first?.t ?? 0, hi = max(c.last?.t ?? 1, lo + 1)
        return SeriesChart(title: title, color: color, samples: c, xDomain: lo...hi,
                           yDomain: niceDomain(c.map(value), minimumSpan: minSpan, floorZero: zero),
                           value: value, marks: meta.marks, showXAxis: true, hover: $hover)
            .padding(10)
            .pane()
    }

    // MARK: Export

    private func save(name: String, type: UTType, write: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? write(url)
    }

    private var fileBase: String { meta.name.replacingOccurrences(of: "/", with: "-") + " " + meta.date.formatted(.iso8601.year().month().day()) }

    private func exportCSV() {
        save(name: fileBase + ".csv", type: .commaSeparatedText) { url in
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: model.store.samplesURL(meta.id), to: url)
        }
    }

    private func exportJSON() {
        save(name: fileBase + ".json", type: .json) { url in
            try model.store.exportJSON(meta)?.write(to: url)
        }
    }

    private func exportPDF() {
        save(name: fileBase + ".pdf", type: .pdf) { url in
            renderReportPDF(meta: meta, samples: samples, to: url)
        }
    }
}

@MainActor
func renderReportPDF(meta: SessionMeta, samples: [Sample], to url: URL) {
    let report = SessionReport(meta: meta, summary: SessionSummary(samples: samples, linkDrops: meta.summary.linkDrops),
                               samples: downsample(samples, limit: 600))
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: report)
    renderer.proposedSize = .init(width: 612, height: 792)
    renderer.render { size, draw in
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

/// Capacity removed at each sample. Below 1 Ah, adds up the current instead of
/// using the DL24P's slow counter, so a short test still draws a real curve.
func capacityPoints(_ samples: [Sample]) -> [(t: Double, q: Double, v: Double, on: Bool)] {
    guard let first = samples.first, let last = samples.last else { return [] }
    let useCounter = (last.milliampHours - first.milliampHours) >= 1000
    var q = 0.0
    var previous = first
    return samples.map { s in
        if useCounter {
            q = (s.milliampHours - first.milliampHours) / 1000
        } else if s.t - previous.t <= 5 {
            q += previous.current * (s.t - previous.t) / 3600
        }
        previous = s
        return (s.t, q, s.voltage, s.loadOn)
    }
}

struct SummaryRow: View {
    let meta: SessionMeta
    let summary: SessionSummary

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            tile("Capacity", formatAh(summary.capacityAh), summary.sampleCount > 0 ? "\(summary.sampleCount.formatted()) samples" : "")
            tile("Energy", formatWh(summary.energyWh), String(format: "Mean %.2f V", summary.meanVoltage))
            tile("Voltage range", String(format: "%.2f to %.2f", summary.maxVoltage, summary.minVoltage), "Volts")
            tile("Mean power", String(format: "%.1f W", summary.meanPower), String(format: "Peak %.1f W", summary.peakPower))
            tile("Peak temperature", String(format: "%.0f °C", summary.peakTemperature), "MOSFET")
            tile("Stopped by", meta.stop?.title ?? "Not set", linkText)
        }
    }

    private var linkText: String {
        summary.linkDrops == 0 ? "Connection held" : summary.linkDrops == 1 ? "Connection dropped once" : "Connection dropped \(summary.linkDrops) times"
    }

    private func tile(_ a: String, _ b: String, _ c: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a).foregroundStyle(Theme.secondary)
            Text(b).font(.system(size: 21, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
            Text(c).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .pane(radius: 14)
    }
}

struct DischargeCurve: View {
    let meta: SessionMeta
    let samples: [Sample]
    let others: [(SessionMeta, [Sample])]

    private struct Line: Identifiable { let id: UUID; let name: String; let points: [(q: Double, v: Double)]; let color: Color }

    private var lines: [Line] {
        func line(_ m: SessionMeta, _ s: [Sample], _ c: Color) -> Line {
            return Line(id: m.id, name: m.name, points: capacityPoints(s).filter { $0.on || s.count < 3 }.map { ($0.q, $0.v) }, color: c)
        }
        var out = [line(meta, samples, Theme.comparison[0])]
        for (i, o) in others.enumerated() where i < 2 { out.append(line(o.0, o.1, Theme.comparison[i + 1])) }
        return out
    }

    private struct MarkPoint: Identifiable { let id: UUID; let q: Double; let text: String }

    private var markPoints: [MarkPoint] {
        let points = capacityPoints(samples)
        return meta.marks.compactMap { m in
            guard let near = points.min(by: { abs($0.t - m.t) < abs($1.t - m.t) }) else { return nil }
            return MarkPoint(id: m.id, q: near.q, text: m.text)
        }
    }

    var body: some View {
        let ls = lines
        let vs = ls.flatMap { $0.points.map(\.v) }
        let qMax = max(ls.flatMap { $0.points.map(\.q) }.max() ?? 0.001, 0.001)
        let yDom = niceDomain(vs, minimumSpan: 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Discharge curve").fontWeight(.semibold)
                Text("Voltage against capacity removed").foregroundStyle(Theme.secondary)
                Spacer()
                if ls.count > 1 {
                    ForEach(ls) { l in
                        HStack(spacing: 5) { Circle().fill(l.color).frame(width: 8, height: 8); Text(l.name).lineLimit(1) }
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Chart {
                ForEach(markPoints) { m in
                    RuleMark(x: .value("Mark", m.q))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: -14) {
                            Text(m.text).font(.caption2).foregroundStyle(Theme.primary).padding(.leading, 5)
                        }
                }
                ForEach(ls) { l in
                    ForEach(l.points.indices, id: \.self) { i in
                        LineMark(x: .value("Ah", l.points[i].q), y: .value("V", l.points[i].v), series: .value("Session", l.id.uuidString))
                            .foregroundStyle(l.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                    if let e = l.points.last {
                        PointMark(x: .value("Ah", e.q), y: .value("V", e.v))
                            .foregroundStyle(l.color).symbolSize(60)
                            .annotation(position: e.q > qMax * 0.4 ? .topLeading : .topTrailing, spacing: 3) {
                                if ls.count == 1 {
                                    Text(formatAh(e.q) + String(format: " at %.2f V", e.v)).font(.caption.weight(.semibold)).foregroundStyle(Theme.primary)
                                }
                            }
                    }
                }
            }
            .chartXScale(domain: 0...(qMax * 1.03))
            .chartYScale(domain: yDom)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(qMax < 1 ? String(format: "%.0f mAh", d * 1000) : String(format: "%g Ah", d)).font(.caption2).foregroundStyle(Theme.secondary) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f", d)).font(.caption2).foregroundStyle(Theme.secondary).monospacedDigit() } }
                }
            }
        }
        .padding(13)
        .pane()
    }
}

struct SampleTable: View {
    let samples: [Sample]
    let marks: [SessionMark]
    let rate: Double
    let hover: Double?

    // Keeps scrolling smooth on long tests. Exports always hold every row.
    private var rows: [Sample] {
        guard samples.count > 3000 else { return samples }
        let step = samples.count / 3000 + 1
        return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
    }

    private func markText(_ s: Sample, next: Double?) -> String {
        marks.first { $0.t >= s.t && $0.t < (next ?? .infinity) }?.text ?? ""
    }

    private let widths: [CGFloat] = [78, 88, 88, 80, 104, 100, 96, 66, 66, 48]

    var body: some View {
        let list = rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Samples").fontWeight(.semibold)
                Text("\(samples.count.formatted()) rows, \(String(format: "%.1f", rate)) Hz").foregroundStyle(Theme.secondary).monospacedDigit()
                if list.count < samples.count {
                    Text("Showing every \(samples.count / list.count + 1)th row. Exports have them all.").foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(list.indices, id: \.self) { i in
                                row(list[i], next: i + 1 < list.count ? list[i + 1].t : nil).id(i)
                            }
                        } header: { header }
                    }
                }
                .onChange(of: hover) { _, h in
                    guard let h, let i = list.firstIndex(where: { $0.t >= h }) else { return }
                    proxy.scrollTo(i, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .pane()
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("Time", 0, .leading); cell("Voltage, V", 1); cell("Current, A", 2); cell("Power, W", 3)
            cell("Capacity, mAh", 4); cell("Energy, mWh", 5); cell("Resistance, Ω", 6); cell("Temp, °C", 7); cell("Set, A", 8); cell("Load", 9)
            Text("Mark").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Color(hex: 0xD5DBE2))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(hex: 0x12181E))
    }

    private func row(_ s: Sample, next: Double?) -> some View {
        HStack(spacing: 0) {
            cell(formatPreciseClock(s.t), 0, .leading)
            cell(String(format: "%.3f", s.voltage), 1); cell(String(format: "%.3f", s.current), 2)
            cell(String(format: "%.2f", s.power), 3); cell(Int(s.milliampHours).formatted(), 4)
            cell(Int(s.milliwattHours).formatted(), 5); cell(s.resistance.map { String(format: "%.3f", $0) } ?? "–", 6)
            cell(String(format: "%.0f", s.temperatureC), 7); cell(String(format: "%.2f", s.setCurrent), 8)
            cell(s.loadOn ? "On" : "Off", 9)
            Text(markText(s, next: next)).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14).lineLimit(1)
        }
        .monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
    }

    private func cell(_ t: String, _ i: Int, _ a: Alignment = .trailing) -> some View {
        Text(t).frame(width: widths[i], alignment: a).lineLimit(1)
    }
}

/// Printable report, always light so it reads on paper.
struct SessionReport: View {
    let meta: SessionMeta
    let summary: SessionSummary
    let samples: [Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meta.name).font(.system(size: 22, weight: .bold))
            Text("DL-X Control test report, \(meta.date.formatted(date: .long, time: .shortened)), connected by \(meta.transport)")
                .font(.system(size: 10))
            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 5) {
                row("Capacity", formatAh(summary.capacityAh))
                row("Energy", formatWh(summary.energyWh))
                row("Duration", formatClock(summary.duration))
                row("Voltage range", String(format: "%.3f V to %.3f V", summary.maxVoltage, summary.minVoltage))
                row("Mean voltage", String(format: "%.3f V", summary.meanVoltage))
                row("Mean and peak power", String(format: "%.1f W, %.1f W", summary.meanPower, summary.peakPower))
                row("Peak MOSFET temperature", String(format: "%.0f °C", summary.peakTemperature))
                row("Stopped by", meta.stop?.title ?? "Not recorded")
                if let r = meta.result?.dcResistanceOhm { row("DC resistance", String(format: "%.1f mΩ", r * 1000)) }
                row("Samples", summary.sampleCount.formatted())
            }
            .font(.system(size: 11).monospacedDigit())
            chart("Voltage, V", .blue, \.voltage)
            chart("Current, A", .orange, \.current)
            chart("Temperature, °C", .brown, \.temperatureC)
            if !meta.marks.isEmpty {
                Text("Marks").font(.system(size: 12, weight: .semibold))
                ForEach(meta.marks) { Text("\(formatClock($0.t))  \($0.text)").font(.system(size: 10).monospacedDigit()) }
            }
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(.black)
    }

    private func row(_ a: String, _ b: String) -> some View {
        GridRow { Text(a).foregroundStyle(.black.opacity(0.65)); Text(b).fontWeight(.medium) }
    }

    private func chart(_ title: String, _ color: Color, _ v: @escaping (Sample) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold))
            Chart(samples) { s in
                LineMark(x: .value("Time", s.t), y: .value(title, v(s))).foregroundStyle(color).lineStyle(.init(lineWidth: 1.5))
            }
            .chartYScale(domain: niceDomain(samples.map(v), minimumSpan: 1))
            .chartXAxis {
                AxisMarks(values: timeTicks((samples.first?.t ?? 0)...max(samples.last?.t ?? 1, (samples.first?.t ?? 0) + 1))) { x in
                    AxisGridLine()
                    AxisValueLabel { if let d = x.as(Double.self) { Text(formatShortClock(d)).font(.system(size: 8)) } }
                }
            }
            .frame(height: 110)
        }
    }
}
