import Charts
import DLXCore
import SwiftUI

struct ProgramList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 2) {
            Text("Programs").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 16)
            List(model.store.programs, selection: $model.selectedProgram) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).fontWeight(.semibold).lineLimit(1)
                    Text(p.kind.subtitle).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .tag(p.id)
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Delete program", role: .destructive) {
                        model.store.savePrograms(model.store.programs.filter { $0.id != p.id })
                        if model.selectedProgram == p.id { model.selectedProgram = model.store.programs.first?.id }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

struct TestsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selectedProgram, let i = model.store.programs.firstIndex(where: { $0.id == id }) {
            ProgramEditor(program: model.store.programs[i]).id(id)
        } else {
            ContentUnavailableView("No program selected", systemImage: "chart.bar.xaxis.ascending").navigationTitle("Tests")
        }
    }
}

struct ProgramEditor: View {
    @Environment(AppModel.self) private var model
    @LocalState var program: TestProgram
    @LocalState private var confirmStart = false

    private var isRunning: Bool { model.device.runningProgramID == program.id }
    private var locked: Bool { model.device.isRunningProgram }
    private var isSaved: Bool { model.store.programs.first { $0.id == program.id } == program }

    var body: some View {
        let d = model.device
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Program name", text: $program.name)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .bold))
                    .disabled(locked)
                ScreenHeader(title: "", actions: {
                    Button("Duplicate") {
                        var copy = program
                        copy.id = UUID(); copy.name += " copy"
                        model.store.savePrograms(model.store.programs + [copy])
                        model.selectedProgram = copy.id
                    }
                    .disabled(locked)
                    Button("Save") { save() }.disabled(isSaved || locked)
                    if isRunning {
                        Button("Stop test") { Task { await d.turnLoadOff(reason: .user) } }
                            .buttonStyle(.glassProminent).tint(Theme.critical).foregroundStyle(.black)
                    } else {
                        Button("Start test") { confirmStart = true }
                            .buttonStyle(.glassProminent).tint(Theme.loadOn).foregroundStyle(.black)
                            .disabled(!d.isConnected || locked || program.steps.isEmpty)
                    }
                })
            }
            .padding(.leading, 4)
            PlanChart(program: program, progress: isRunning ? d.runProgress : nil)
                .frame(height: 230)
            HStack(alignment: .top, spacing: 10) {
                StepsTable(program: $program, locked: locked, activeStep: isRunning ? d.run?.stepIndex : nil)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    StopsCard(stops: $program.stops, locked: locked)
                    ResultCard(program: program)
                }
                .frame(width: 400)
            }
        }
        .confirmationDialog("Start \(program.name)?", isPresented: $confirmStart) {
            Button("Panel is in CC, start") { save(); d.runProgram(program) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set the DL24P's front panel to CC first. The app cannot read the panel mode, and in CV or CR the load ignores the program's current. The DL24P's own timer is turned off for the test.\n\nPeak current: \(String(format: "%.2f A", program.steps.map(\.current).max() ?? 0))")
        }
    }

    private func save() {
        var list = model.store.programs
        if let i = list.firstIndex(where: { $0.id == program.id }) { list[i] = program }
        model.store.savePrograms(list)
    }
}

struct PlanChart: View {
    let program: TestProgram
    let progress: (step: Int, of: Int, elapsed: Double)?

    private struct Seg: Identifiable { let id: Int; let t0: Double; let t1: Double; let a: Double }

    private var segments: [Seg] {
        var t = 0.0
        return program.steps.enumerated().map { i, s in
            // An open-ended step is drawn at a nominal width with a note above.
            let d = s.duration ?? max(60, (program.totalDurationKnown) * 0.3)
            defer { t += d }
            return Seg(id: i, t0: t, t1: t + d, a: s.current)
        }
    }

    var body: some View {
        let segs = segments
        let hi = max(segs.map(\.a).max() ?? 1, 0.5)
        let duration = segs.last?.t1 ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Planned current").fontWeight(.semibold)
                Text(summary).foregroundStyle(Theme.secondary).monospacedDigit()
                Spacer()
                if let p = progress {
                    Text("Running step \(p.step) of \(p.of), \(formatClock(p.elapsed))").fontWeight(.semibold).monospacedDigit()
                }
            }
            Chart {
                ForEach(segs) { s in
                    RectangleMark(xStart: .value("Start", s.t0), xEnd: .value("End", s.t1), yStart: .value("Base", 0), yEnd: .value("Current", s.a))
                        .foregroundStyle(Theme.current.opacity(progress != nil && s.id == (progress!.step - 1) ? 0.5 : 0.17))
                    LineMark(x: .value("t", s.t0), y: .value("A", s.a), series: .value("s", "plan")).foregroundStyle(Theme.current)
                    LineMark(x: .value("t", s.t1), y: .value("A", s.a), series: .value("s", "plan")).foregroundStyle(Theme.current)
                    if s.a > 0 {
                        PointMark(x: .value("t", (s.t0 + s.t1) / 2), y: .value("A", s.a))
                            .opacity(0)
                            .annotation(position: .top, spacing: 2) {
                                Text(String(format: "%g A", s.a)).font(.caption).foregroundStyle(Theme.primary)
                            }
                    }
                }
            }
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: 0...(hi * 1.25))
            .chartXAxis(program.totalDuration == nil ? .hidden : .automatic)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(formatShortClock(d)).font(.caption2).foregroundStyle(Theme.secondary) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%g", d)).font(.caption2).foregroundStyle(Theme.secondary).monospacedDigit() } }
                }
            }
        }
        .padding(13)
        .pane()
    }

    private var summary: String {
        let n = program.steps.count
        guard let total = program.totalDuration, let ah = program.plannedAh else {
            return "\(n) \(n == 1 ? "step" : "steps"), runs until a stop condition"
        }
        let removed = ah < 0.1 ? String(format: "%.1f mAh", ah * 1000) : String(format: "%.2f Ah", ah)
        return "\(n) \(n == 1 ? "step" : "steps"), \(formatShortClock(total)) total, about \(removed) removed"
    }
}

private extension TestProgram {
    var totalDurationKnown: Double { steps.compactMap(\.duration).reduce(0, +) }
}

struct StepsTable: View {
    @Binding var program: TestProgram
    let locked: Bool
    let activeStep: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Steps").fontWeight(.semibold)
                Spacer()
                Button("Add step") {
                    program.steps.append(TestStep(current: program.steps.last?.current ?? 1, duration: 30))
                }
                .buttonStyle(.glass).disabled(locked)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 0) {
                Text("Step").frame(width: 48, alignment: .leading)
                Text("Action").frame(width: 70, alignment: .leading)
                Text("Current, A").frame(width: 96, alignment: .trailing)
                Text("Duration, s").frame(width: 110, alignment: .trailing)
                Text("Until stop").frame(width: 92, alignment: .trailing)
                Spacer()
            }
            .fontWeight(.semibold).foregroundStyle(Color(hex: 0xD5DBE2))
            .padding(.horizontal, 12).padding(.bottom, 5)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($program.steps) { $step in
                        let i = program.steps.firstIndex { $0.id == step.id } ?? 0
                        HStack(spacing: 0) {
                            Text("\(i + 1)").frame(width: 48, alignment: .leading)
                            Text(step.isRest ? "Rest" : "Hold").frame(width: 70, alignment: .leading)
                            TextField("Current", value: $step.current, format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 96)
                            TextField("Duration", value: Binding(get: { step.duration ?? 0 }, set: { step.duration = $0 }),
                                      format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 110)
                                .disabled(step.duration == nil)
                            Toggle("Until stop", isOn: Binding(get: { step.duration == nil }, set: { step.duration = $0 ? nil : 60 }))
                                .labelsHidden().frame(width: 92, alignment: .trailing)
                            Spacer()
                            Button { program.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove step \(i + 1)")
                        }
                        .monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(activeStep == i ? Color.white.opacity(0.1) : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
                    }
                }
            }
            .disabled(locked)
        }
        .frame(maxHeight: .infinity)
        .pane()
    }
}

struct StopsCard: View {
    @Binding var stops: StopConditions
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop the load if any of these happen").fontWeight(.semibold)
            row("Voltage falls below", $stops.cutoffEnabled, $stops.cutoffV, "V")
            row("Temperature rises above", $stops.temperatureEnabled, $stops.temperatureC, "°C")
            row("Power rises above", $stops.powerEnabled, $stops.powerW, "W")
            row("Capacity removed reaches", $stops.capacityEnabled, $stops.capacityAh, "Ah")
            Toggle("Current overshoots the setting", isOn: $stops.overshootEnabled)
            Text("If the connection drops, the DL24P's own cutoff and timer keep working. The app turns the load off when it reconnects.")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .disabled(locked)
    }

    private func row(_ label: String, _ on: Binding<Bool>, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Toggle(label, isOn: on)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 60)
                .fontWeight(.semibold).monospacedDigit().disabled(!on.wrappedValue)
            Text(unit).frame(width: 22, alignment: .leading).foregroundStyle(Theme.secondary)
        }
        .frame(height: 26)
    }
}

struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let program: TestProgram

    var body: some View {
        let results = model.store.lastResults(named: program.name)
        VStack(alignment: .leading, spacing: 7) {
            Text("Last result for this program").fontWeight(.semibold)
            if let r = results.first {
                Text(headline(r)).font(.system(size: 30, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(detail(r)).foregroundStyle(Color(hex: 0xD5DBE2)).fixedSize(horizontal: false, vertical: true)
                if results.count > 1 {
                    Text("Previous run: \(headline(results[1])), \(results[1].date.formatted(.dateTime.month(.abbreviated).day()))").foregroundStyle(Theme.secondary)
                }
                if r.kind == .sweep, !r.steps.isEmpty {
                    Divider()
                    ForEach(r.steps.suffix(4)) { s in
                        Text(String(format: "%.2f A  %.3f V", s.measuredCurrent, s.voltage)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                Text("This program has not run yet.").foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane()
    }

    private func headline(_ r: ProgramResult) -> String {
        if r.kind == .internalResistance, let o = r.dcResistanceOhm { return String(format: "%.1f mΩ", o * 1000) }
        if r.kind == .sweep, let o = r.dcResistanceOhm { return String(format: "%.0f mΩ source", o * 1000) }
        return String(format: "%.2f Ah", r.capacityAh)
    }

    private func detail(_ r: ProgramResult) -> String {
        let end = "Stopped by: \(r.stop.title.lowercased())."
        if r.kind == .internalResistance || r.kind == .sweep, r.dcResistanceOhm != nil {
            return "From the last two load steps. \(end)"
        }
        return String(format: "%.1f Wh. ", r.energyWh) + end
    }
}
