import Foundation

public struct Sample: Codable, Equatable, Sendable, Identifiable {
    public var t: Double          // seconds since the start of the session or buffer
    public var voltage: Double
    public var current: Double
    public var milliampHours: Double
    public var milliwattHours: Double
    public var temperatureC: Double
    public var setCurrent: Double
    public var loadOn: Bool

    public var id: Double { t }
    public var power: Double { voltage * current }
    public var resistance: Double? { current > 0.01 ? voltage / current : nil }

    public init(t: Double, voltage: Double, current: Double, milliampHours: Double, milliwattHours: Double,
                temperatureC: Double, setCurrent: Double, loadOn: Bool) {
        self.t = t; self.voltage = voltage; self.current = current
        self.milliampHours = milliampHours; self.milliwattHours = milliwattHours
        self.temperatureC = temperatureC; self.setCurrent = setCurrent; self.loadOn = loadOn
    }
}

public enum ControlMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case cc = "CC", cp = "CP", cr = "CR"
    public var id: String { rawValue }
    public var unit: String { self == .cc ? "A" : self == .cp ? "W" : "Ω" }
    public var setpointName: String { self == .cc ? "Current" : self == .cp ? "Power" : "Resistance" }
}

public enum Regulator {
    public static let minimumVoltage = 0.5
    public static let maxStepAmps = 0.5

    /// The DL24P only regulates current over its link, so CP and CR are run by
    /// the app. The result is always clamped to the limit, slew limited, and
    /// zero when there is too little voltage to compute a sensible current.
    public static func current(mode: ControlMode, target: Double, voltage: Double,
                               previous: Double, limit: Double) -> Double {
        let limit = max(0, limit)
        let wanted: Double
        switch mode {
        case .cc: return min(max(target, 0), limit)
        case .cp:
            guard voltage >= minimumVoltage else { return 0 }
            wanted = target / voltage
        case .cr:
            guard voltage >= minimumVoltage, target > 0 else { return 0 }
            wanted = voltage / target
        }
        let stepped = min(wanted, previous + maxStepAmps)
        let down = max(stepped, previous - maxStepAmps)
        return ((min(max(down, 0), limit)) * 100).rounded() / 100
    }
}

public enum StopReason: Codable, Equatable, Sendable {
    case user, cutoff, temperature, power, capacity, overshoot(current: Double, set: Double)
    case linkLost, timeLimit, finished, deviceTurnedOff, deviceRejectedSetting

    public var title: String {
        switch self {
        case .user: "Stopped by you"
        case .cutoff: "Cutoff"
        case .temperature: "Temperature limit"
        case .power: "Power limit"
        case .capacity: "Capacity limit"
        case .overshoot: "Current overshoot"
        case .linkLost: "Connection lost"
        case .timeLimit: "DL24P timer ran out"
        case .finished: "Finished"
        case .deviceTurnedOff: "Load turned off on the DL24P"
        case .deviceRejectedSetting: "The DL24P rejected a setting"
        }
    }

    public var detail: String {
        switch self {
        case .overshoot(let i, let s):
            String(format: "Measured %.2f A with %.2f A set. Check the front panel is in CC.", i, s)
        case .linkLost: "The app turned the load off when the connection came back. The DL24P's own cutoff and timer stay active while disconnected."
        case .deviceTurnedOff: "The DL24P's cutoff, timer or front panel may have stopped it."
        case .deviceRejectedSetting: "The app turned the load off, because it could not confirm the current in use."
        case .cutoff: "Voltage fell to the cutoff."
        case .temperature: "The MOSFET reached the temperature limit."
        case .power: "Power rose above the limit."
        case .capacity: "The capacity limit was reached."
        case .timeLimit: "The DL24P's own timer ran out, which stops the load and turns the timer off."
        case .user, .finished: ""
        }
    }
}

public struct StopConditions: Codable, Equatable, Sendable {
    public var cutoffEnabled = true
    public var cutoffV = 5.0
    public var temperatureEnabled = true
    public var temperatureC = 75.0
    public var powerEnabled = true
    public var powerW = 150.0
    public var capacityEnabled = false
    public var capacityAh = 20.0
    public var overshootEnabled = true

    public init() {}
}

/// App-side protection. Evaluated on every sample while the load is on.
public struct GuardEngine: Sendable {
    public var stops: StopConditions
    public static let confirmSamples = 3
    public static let setpointGrace = 0.6

    private var cutoffCount = 0, tempCount = 0, powerCount = 0, overshootCount = 0
    private var lastSetpointChange: Double = -.infinity
    private var lastSet: Double?

    public init(stops: StopConditions) { self.stops = stops }

    public mutating func reset() {
        cutoffCount = 0; tempCount = 0; powerCount = 0; overshootCount = 0
        lastSet = nil; lastSetpointChange = -.infinity
    }

    /// `capacity` is the amount removed since the load started, in Ah.
    public mutating func evaluate(_ s: Sample, capacityAh: Double) -> StopReason? {
        guard s.loadOn else { reset(); return nil }
        // Only lowering a setpoint needs time to settle. At load-on the current rises
        // from zero, so anything above the setting is already wrong.
        if let previous = lastSet, previous != s.setCurrent {
            if s.setCurrent < previous { lastSetpointChange = s.t }
        }
        lastSet = s.setCurrent

        func count(_ c: inout Int, _ cond: Bool) -> Bool { c = cond ? c + 1 : 0; return c >= Self.confirmSamples }

        let overLimit = s.current > s.setCurrent * 1.1 + 0.1
        let inGrace = s.t - lastSetpointChange < Self.setpointGrace
        // Far above the setting, there is no time to wait for confirmation. The poll
        // loop has already re-read any jump, so a glitch does not reach this point.
        if stops.overshootEnabled, !inGrace, s.current > s.setCurrent * 2 + 0.5 {
            return .overshoot(current: s.current, set: s.setCurrent)
        }
        if stops.overshootEnabled, count(&overshootCount, overLimit && !inGrace) {
            return .overshoot(current: s.current, set: s.setCurrent)
        }
        if stops.temperatureEnabled, count(&tempCount, s.temperatureC >= stops.temperatureC) { return .temperature }
        if stops.powerEnabled, count(&powerCount, s.power >= stops.powerW) { return .power }
        if stops.cutoffEnabled, count(&cutoffCount, s.voltage <= stops.cutoffV) { return .cutoff }
        if stops.capacityEnabled, capacityAh >= stops.capacityAh { return .capacity }
        return nil
    }
}

// MARK: - Test programs

public enum ProgramKind: String, Codable, CaseIterable, Sendable {
    case capacity, internalResistance, sweep, soak, custom
    public var title: String {
        switch self {
        case .capacity: "Capacity"
        case .internalResistance: "Internal resistance"
        case .sweep: "Supply sweep"
        case .soak: "Soak"
        case .custom: "Custom sequence"
        }
    }
    public var subtitle: String {
        switch self {
        case .capacity: "Discharge to cutoff"
        case .internalResistance: "Current steps, DC resistance"
        case .sweep: "Voltage sag against current"
        case .soak: "Hold load, watch heat"
        case .custom: "Your own steps"
        }
    }
}

public struct TestStep: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var current: Double       // 0 turns the load off for the step
    public var duration: Double?     // nil runs until a stop condition
    public init(current: Double, duration: Double?) { self.current = current; self.duration = duration }
    public var isRest: Bool { current <= 0 }
}

public struct TestProgram: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kind: ProgramKind
    public var steps: [TestStep]
    public var stops: StopConditions

    public init(name: String, kind: ProgramKind, steps: [TestStep], stops: StopConditions = .init()) {
        self.name = name; self.kind = kind; self.steps = steps; self.stops = stops
    }

    public var totalDuration: Double? {
        var t = 0.0
        for s in steps { guard let d = s.duration else { return nil }; t += d }
        return t
    }
    public var plannedAh: Double? {
        var t = 0.0
        for s in steps { guard let d = s.duration else { return nil }; t += s.current * d / 3600 }
        return t
    }

    public static var templates: [TestProgram] {
        var batt = StopConditions(); batt.cutoffV = 10.5
        return [
            TestProgram(name: "Capacity", kind: .capacity, steps: [TestStep(current: 5, duration: nil)], stops: batt),
            TestProgram(name: "Internal resistance", kind: .internalResistance, steps: [
                .init(current: 0, duration: 20), .init(current: 2, duration: 30), .init(current: 0, duration: 20),
                .init(current: 5, duration: 30), .init(current: 10, duration: 20), .init(current: 0, duration: 20),
            ], stops: batt),
            TestProgram(name: "Supply sweep", kind: .sweep, steps: stride(from: 0.5, through: 5, by: 0.5).map {
                TestStep(current: $0, duration: 10)
            }),
            TestProgram(name: "Soak", kind: .soak, steps: [TestStep(current: 2, duration: 3600)]),
            TestProgram(name: "Custom sequence", kind: .custom, steps: [
                .init(current: 1, duration: 60), .init(current: 0, duration: 30),
            ]),
        ]
    }
}

public struct StepResult: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var current: Double
    public var measuredCurrent: Double
    public var voltage: Double
    public init(index: Int, current: Double, measuredCurrent: Double, voltage: Double) {
        self.index = index; self.current = current; self.measuredCurrent = measuredCurrent; self.voltage = voltage
    }
}

public struct ProgramResult: Codable, Equatable, Sendable {
    public var programName: String
    public var kind: ProgramKind
    public var steps: [StepResult]
    public var dcResistanceOhm: Double?
    public var capacityAh: Double
    public var energyWh: Double
    public var stop: StopReason
    public var date: Date

    public init(programName: String, kind: ProgramKind, steps: [StepResult], dcResistanceOhm: Double?,
                capacityAh: Double, energyWh: Double, stop: StopReason, date: Date) {
        self.programName = programName; self.kind = kind; self.steps = steps
        self.dcResistanceOhm = dcResistanceOhm; self.capacityAh = capacityAh; self.energyWh = energyWh
        self.stop = stop; self.date = date
    }

    /// DC resistance from the last two load steps with different currents.
    public static func dcResistance(_ steps: [StepResult]) -> Double? {
        let loaded = steps.filter { $0.measuredCurrent > 0.01 }
        guard let b = loaded.last,
              let a = loaded.dropLast().last(where: { abs($0.measuredCurrent - b.measuredCurrent) > 0.05 }) else { return nil }
        return abs((a.voltage - b.voltage) / (a.measuredCurrent - b.measuredCurrent))
    }
}

public enum ProgramAction: Equatable, Sendable {
    case setCurrent(Double), loadOn, loadOff, finished(StopReason)
}

/// Pure state machine for a program. The caller feeds samples and carries out
/// the actions, which keeps every path testable without hardware.
public struct ProgramRun: Sendable {
    public let program: TestProgram
    public private(set) var stepIndex = 0
    public private(set) var results: [StepResult] = []
    public private(set) var isFinished = false
    private var stepStart: Double = 0
    private var last: Sample?

    public init(program: TestProgram) { self.program = program }

    public var currentStep: TestStep? { program.steps.indices.contains(stepIndex) ? program.steps[stepIndex] : nil }

    private func enter(_ step: TestStep) -> [ProgramAction] {
        step.isRest ? [.loadOff] : [.setCurrent(step.current), .loadOn]
    }

    public mutating func start(at t: Double) -> [ProgramAction] {
        guard let first = program.steps.first else { isFinished = true; return [.finished(.finished)] }
        stepStart = t
        return enter(first)
    }

    public func stepElapsed(at t: Double) -> Double { t - stepStart }

    public mutating func tick(_ s: Sample) -> [ProgramAction] {
        guard !isFinished, let step = currentStep else { return [] }
        last = s
        guard let d = step.duration, s.t - stepStart >= d else { return [] }
        results.append(.init(index: stepIndex, current: step.current, measuredCurrent: s.current, voltage: s.voltage))
        stepIndex += 1
        stepStart = s.t
        guard let next = currentStep else {
            isFinished = true
            return [.loadOff, .finished(.finished)]
        }
        return enter(next)
    }

    public mutating func abort(_ reason: StopReason) -> [ProgramAction] {
        guard !isFinished else { return [] }
        if let s = last, let step = currentStep {
            results.append(.init(index: stepIndex, current: step.current, measuredCurrent: s.current, voltage: s.voltage))
        }
        isFinished = true
        return [.loadOff, .finished(reason)]
    }
}

// MARK: - Analysis

public struct SessionSummary: Codable, Equatable, Sendable {
    public var duration: Double = 0
    public var capacityAh: Double = 0
    public var energyWh: Double = 0
    public var minVoltage: Double = 0
    public var maxVoltage: Double = 0
    public var meanPower: Double = 0
    public var peakPower: Double = 0
    public var peakTemperature: Double = 0
    public var sampleCount: Int = 0
    public var linkDrops: Int = 0
    public var meanVoltage: Double { capacityAh > 0 ? energyWh / capacityAh : 0 }

    public init() {}

    /// Uses the device's counters, so a test keeps its totals if samples drop.
    public init(samples: [Sample], linkDrops: Int = 0) {
        self.linkDrops = linkDrops
        sampleCount = samples.count
        guard let first = samples.first, let last = samples.last else { return }
        duration = last.t - first.t
        capacityAh = max(0, last.milliampHours - first.milliampHours) / 1000
        energyWh = max(0, last.milliwattHours - first.milliwattHours) / 1000
        // The DL24P's energy counter moves in 100 mWh steps and updates slowly, which
        // is useless for a short test. Below 1 Ah and 1 Wh, add up the samples instead.
        if capacityAh < 1, energyWh < 1 {
            var ah = 0.0, wh = 0.0
            for (a, b) in zip(samples, samples.dropFirst()) where b.t - a.t <= 5 {
                let hours = (b.t - a.t) / 3600
                ah += a.current * hours
                wh += a.power * hours
            }
            capacityAh = ah
            energyWh = wh
        }
        let loaded = samples.filter { $0.loadOn && $0.current > 0.001 }
        let basis = loaded.isEmpty ? samples : loaded
        minVoltage = basis.map(\.voltage).min() ?? 0
        maxVoltage = basis.map(\.voltage).max() ?? 0
        meanPower = basis.reduce(0) { $0 + $1.power } / Double(basis.count)
        peakPower = basis.map(\.power).max() ?? 0
        peakTemperature = samples.map(\.temperatureC).max() ?? 0
    }
}

/// Averages samples into at most `limit` buckets, keeping the first and last.
public func downsample(_ samples: [Sample], limit: Int) -> [Sample] {
    guard limit > 2, samples.count > limit else { return samples }
    let size = Double(samples.count) / Double(limit - 2)
    var out = [samples[0]]
    var firstBucket = true
    out.reserveCapacity(limit)
    var start = 0.0
    while start < Double(samples.count) {
        let lo = Int(start), hi = min(samples.count, Int(start + size))
        if hi > lo {
            let slice = samples[lo..<hi]
            let n = Double(slice.count)
            var m = slice[slice.startIndex]
            m.t = slice.reduce(0) { $0 + $1.t } / n
            m.voltage = slice.reduce(0) { $0 + $1.voltage } / n
            m.current = slice.reduce(0) { $0 + $1.current } / n
            m.temperatureC = slice.reduce(0) { $0 + $1.temperatureC } / n
            if !(firstBucket && m.t <= samples[0].t) { out.append(m) }
            firstBucket = false
        }
        start += size
    }
    if let tail = samples.last, let prior = out.last, prior.t >= tail.t { out.removeLast() }
    if let tail = samples.last { out.append(tail) }
    return out
}

public enum SampleCSV {
    public static let header = "time_s,voltage_V,current_A,power_W,capacity_mAh,energy_mWh,resistance_ohm,temperature_C,set_current_A,load_on"

    public static func row(_ s: Sample) -> String {
        String(format: "%.3f,%.3f,%.3f,%.3f,%.0f,%.0f,%@,%.0f,%.2f,%d",
               s.t, s.voltage, s.current, s.power, s.milliampHours, s.milliwattHours,
               s.resistance.map { String(format: "%.3f", $0) } ?? "", s.temperatureC, s.setCurrent, s.loadOn ? 1 : 0)
    }

    public static func parse(line: Substring) -> Sample? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 10, let t = Double(f[0]), let v = Double(f[1]), let i = Double(f[2]),
              let c = Double(f[4]), let e = Double(f[5]), let tc = Double(f[7]),
              let set = Double(f[8]) else { return nil }
        return Sample(t: t, voltage: v, current: i, milliampHours: c, milliwattHours: e,
                      temperatureC: tc, setCurrent: set, loadOn: f[9] == "1")
    }
}
