import AppKit
import Charts
import DLXCore
import SwiftUI
import UniformTypeIdentifiers

struct MonitorView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var hover: Double?
    @LocalState private var showMark = false
    @LocalState private var markText = ""

    var body: some View {
        let d = model.device
        VStack(spacing: 8) {
            ScreenHeader(title: "Monitor", chip: d.isDemo ? "Demo data" : nil) {
                Button {
                    if d.recorder == nil { d.startRecording(name: "Recording") } else { d.stopRecordingNow(stop: nil) }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(d.recorder == nil ? Color.white.opacity(0.5) : Color(hex: 0xFF5F57)).frame(width: 9, height: 9)
                        if d.recorder == nil {
                            Text("Record")
                        } else {
                            Text("Recording, \(Int(d.sampleRate.rounded())) Hz").fontWeight(.semibold)
                            Text(formatClock(d.recordingSeconds)).foregroundStyle(Theme.secondary).monospacedDigit()
                        }
                    }
                }
                .help(d.recorder == nil ? "Start recording a session" : "Stop recording")
                Button("Add mark") { markText = ""; showMark = true }.disabled(d.recorder == nil)
            }
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    ReadoutRow()
                    ChartsPanel(hover: $hover)
                }
                .frame(maxWidth: .infinity)
                ControlPanel()
            }
        }
        .alert("Add mark", isPresented: $showMark) {
            TextField("What happened?", text: $markText)
            Button("Add") { d.addMark(markText.isEmpty ? "Mark" : markText) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The mark appears on the charts and in the exported data.") }
    }
}

struct ReadoutRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.device
        let p = d.voltage * d.current
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            Readout(title: "Voltage", value: String(format: "%.3f", d.voltage), unit: "V", color: Theme.voltage)
            Readout(title: "Current", value: String(format: "%.3f", d.current), unit: "A", color: Theme.current)
            Readout(title: "Power", value: String(format: p >= 100 ? "%.1f" : "%.2f", p), unit: "W", color: Theme.power)
            Readout(title: "Load resistance", value: d.current > 0.01 ? String(format: "%.3f", d.voltage / d.current) : "–", unit: "Ω", color: nil)
        }
    }
}

struct Readout: View {
    let title: String
    let value: String
    let unit: String
    let color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if let color { Circle().fill(color).frame(width: 9, height: 9) }
                Text(title).foregroundStyle(Theme.secondary).fontWeight(.medium)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 38, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 11)
        .pane()
        .accessibilityElement(children: .combine)
    }
}

struct ChartsPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var hover: Double?
    @LocalState private var window = 2

    private let windows: [(String, Double?)] = [("5 min", 300), ("30 min", 1800), ("All", nil)]

    var body: some View {
        let d = model.device
        let samples = d.chartSamples
        let xLo = samples.first?.t ?? 0
        let xHi = max(samples.last?.t ?? 60, xLo + 10)
        let dom = xLo...xHi
        let cut = d.stops.cutoffV
        let row = hoveredSample(samples)
        let marks = d.recorder?.meta.marks ?? []

        VStack(spacing: 2) {
            HStack(spacing: 14) {
                Text(hover == nil ? "Latest" : "At cursor").fontWeight(.semibold)
                Text(formatClock(row?.t ?? 0))
                Spacer()
                Text(String(format: "%.3f V", row?.voltage ?? 0))
                Text(String(format: "%.3f A", row?.current ?? 0))
                Text(String(format: "%.2f W", row?.power ?? 0))
                Text(String(format: "%.0f °C", row?.temperatureC ?? 0))
                Picker("Time window", selection: $window) {
                    ForEach(windows.indices, id: \.self) { Text(windows[$0].0).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                .onChange(of: window) { _, w in d.chartWindow = windows[w].1; d.refreshChart() }
            }
            .monospacedDigit()
            .foregroundStyle(Theme.secondary)
            .frame(height: 30)

            if samples.isEmpty {
                ContentUnavailableView(d.isConnected ? "Starting charts" : "Waiting for a DL24P", systemImage: "waveform.path.ecg",
                                       description: Text(d.isConnected ? "The next readings appear here." : "Charts start as soon as a DL24P is connected."))
                    .frame(maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let h = geo.size.height
                    VStack(spacing: 2) {
                        SeriesChart(title: "Voltage, V", color: Theme.voltage, samples: samples, xDomain: dom,
                                    yDomain: niceDomain(samples.map(\.voltage), minimumSpan: 1, include: cut > 0 ? [cut] : []),
                                    value: \.voltage, rule: cut > 0 ? (cut, String(format: "Cutoff %.2f V", cut)) : nil,
                                    marks: marks, hover: $hover)
                            .frame(height: h * 0.4)
                        SeriesChart(title: "Current, A", color: Theme.current, samples: samples, xDomain: dom,
                                    yDomain: niceDomain(samples.map(\.current) + samples.map(\.setCurrent), minimumSpan: 1, floorZero: true),
                                    value: \.current, marks: marks, hover: $hover)
                            .frame(height: h * 0.27)
                        SeriesChart(title: "Power, W", color: Theme.power, samples: samples, xDomain: dom,
                                    yDomain: niceDomain(samples.map(\.power), minimumSpan: 5, floorZero: true),
                                    value: \.power, marks: marks, showXAxis: true, hover: $hover)
                            .frame(height: h * 0.33 - 4)
                    }
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .pane()
    }

    private func hoveredSample(_ s: [Sample]) -> Sample? {
        guard let h = hover else { return s.last }
        return s.min { abs($0.t - h) < abs($1.t - h) }
    }
}

struct ControlPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var d = model.device
        ScrollView {
            VStack(spacing: 13) {
                LoadButton()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Mode").fontWeight(.semibold)
                    Picker("Mode", selection: $d.mode) {
                        ForEach(ControlMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .disabled(d.isRunningProgram)
                    Text(modeNote(d.mode))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    switch d.mode {
                    case .cc:
                        SetpointField(label: "Current", unit: "A", value: d.ccTarget, step: 0.1, decimals: 2,
                                      range: Command.currentRange, disabled: !d.isConnected) { d.applyCurrent($0) }
                    case .cp:
                        SetpointField(label: "Power", unit: "W", value: d.cpTarget, step: 1, decimals: 1,
                                      range: 0...200) { d.cpTarget = $0 }
                        SetpointField(label: "Limit", unit: "A", value: d.currentLimit, step: 0.5, decimals: 2,
                                      range: Command.currentRange) { d.currentLimit = $0 }
                    case .cr:
                        SetpointField(label: "Resistance", unit: "Ω", value: d.crTarget, step: 0.5, decimals: 2,
                                      range: 0.1...10000) { d.crTarget = $0 }
                        SetpointField(label: "Limit", unit: "A", value: d.currentLimit, step: 0.5, decimals: 2,
                                      range: Command.currentRange) { d.currentLimit = $0 }
                    case .cccv:
                        SetpointField(label: "CC current", unit: "A", value: d.cccv.current, step: 0.1, decimals: 2,
                                      range: Command.currentRange) { d.cccv.current = $0 }
                        SetpointField(label: "CV target", unit: "V", value: d.cccv.targetVoltage, step: 0.1, decimals: 2,
                                      range: 0.1...Command.cutoffRange.upperBound) { d.cccv.targetVoltage = $0 }
                        SetpointField(label: "End current", unit: "A", value: d.cccv.endCurrent, step: 0.05, decimals: 2,
                                      range: 0.02...Command.currentRange.upperBound) { d.cccv.endCurrent = $0 }
                    }
                    SetpointField(label: "Cutoff", unit: "V", value: d.deviceCutoff, step: 0.1, decimals: 2,
                                  range: Command.cutoffRange, disabled: !d.isConnected) { d.applyCutoff($0) }
                    SetpointField(label: "Timer left", unit: "min", value: Double(d.deviceTimerSeconds) / 60, step: 1, decimals: 0,
                                  range: 0...1092, offText: "Off", disabled: !d.isConnected) { d.applyTimer(minutes: Int($0)) }
                }

                if d.mode == .cccv { CCCVStatus() }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    stat("Capacity", String(format: "%.3f Ah", d.milliampHours / 1000))
                    stat("Energy", String(format: "%.2f Wh", d.milliwattHours / 1000))
                    stat("DL24 run time", formatClock(Double(d.runSeconds)))
                }
                .monospacedDigit()

                TemperatureMeter(celsius: d.temperatureC, limit: d.stops.temperatureC)

                Toggle("Record whenever the load runs", isOn: $d.autoRecord)
                    .toggleStyle(.switch).controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("Turn load off").foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("⌘ .")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: .rect(cornerRadius: 7))
                }
            }
            .padding(14)
        }
        .scrollIndicators(.never)
        .frame(width: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func modeNote(_ m: ControlMode) -> String {
        switch m {
        case .cc: "Holds constant current on the DL24P. Set its front panel to CC first, because the app cannot read the panel mode."
        case .cp: "Holds constant power. This app adjusts the current, fastest over USB. Set the front panel to CC first."
        case .cr: "Holds constant resistance. This app adjusts the current, fastest over USB. Set the front panel to CC first."
        case .cccv: "Sinks the CC current until the voltage falls to the CV target, then lowers it to hold that voltage, and stops at the end current. This app adjusts the current, up to twice a second. Set the front panel to CC first."
        }
    }

    private func stat(_ a: String, _ b: String) -> some View {
        GridRow {
            Text(a).foregroundStyle(Color(hex: 0xD5DBE2))
            Text(b).font(.system(size: 16, weight: .semibold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The CC-CV phase while running, and anything that would stop it working.
struct CCCVStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 6) {
            if d.loadOn, let phase = d.cccvPhase {
                Text(phaseText(phase, d)).fontWeight(.semibold).monospacedDigit()
            }
            ForEach(d.cccvIssues.indices, id: \.self) { i in
                Label(d.cccvIssues[i].message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(d.cccvIssues[i].blocksStart ? Theme.critical : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseText(_ phase: CCCVRegulator.Phase, _ d: DeviceController) -> String {
        switch phase {
        case .constantCurrent: String(format: "CC phase: sinking up to %.2f A", d.cccv.current)
        case .constantVoltage: String(format: "CV phase: holding %.2f V, ends at %.2f A", d.cccv.targetVoltage, d.cccv.endCurrent)
        }
    }
}

struct LoadButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.device
        Button { d.toggleLoad() } label: {
            VStack(spacing: 2) {
                Text(d.loadOn ? "Load is on" : "Load is off").font(.system(size: 18, weight: .bold))
                Text(subtitle(d)).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .foregroundStyle(d.loadOn ? Color(hex: 0x201400) : Theme.primary)
            .contentShape(.rect)
        }
        .modifier(LoadButtonStyle(on: d.loadOn))
        .disabled(!d.isConnected || d.loadBusy)
        .accessibilityValue(d.loadOn ? "On" : "Off")
    }

    private func subtitle(_ d: DeviceController) -> String {
        if !d.isConnected { return "Waiting for a DL24P" }
        if d.loadBusy { return "Working…" }
        return d.loadOn ? "Click to turn off" : "Click to start sinking current"
    }
}

private struct LoadButtonStyle: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content.buttonStyle(.glassProminent).tint(Theme.loadOn).buttonBorderShape(.roundedRectangle(radius: 18))
        } else {
            content.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 18))
        }
    }
}

struct TemperatureMeter: View {
    let celsius: Double
    let limit: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("MOSFET temperature").foregroundStyle(Color(hex: 0xD5DBE2))
                Spacer()
                Text(String(format: "%.0f °C", celsius)).fontWeight(.semibold).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(celsius >= limit * 0.9 ? Theme.critical : Theme.primary)
                        .frame(width: geo.size.width * min(max(celsius / max(limit, 1), 0), 1))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack {
                Text("App stops the load at \(Int(limit)) °C, or if current overshoots the setting")
                    .font(.caption2).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}
