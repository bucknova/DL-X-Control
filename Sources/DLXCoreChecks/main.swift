import DLXCore
import Foundation

// Runs without Xcode's test tools: `swift run DLXCoreChecks`. Expected bytes
// below are real ones captured from a DL24P, not computed values.

var failures = 0, passed = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if ok { passed += 1 } else { failures += 1; print("FAIL line \(line): \(name)") }
}
func near(_ a: Double, _ b: Double, _ e: Double = 0.0005) -> Bool { abs(a - b) <= e }

// MARK: Captured status frame
let capture = parseHex("ff 55 01 02 00 00 00 00 00 00 00 0f 9c 00 00 00 1c 00 00 00 00 00 00 00 00 19 00 13 0c 09 3c 00 00 00 00 03")!
if let r = StatusReport(frame: capture) {
    check(near(r.capacityAh, 39.96), "capacity scale")
    check(near(r.energyWh, 280), "energy scale, 0x1c x 10 Wh")
    check(r.temperatureC == 25, "temperature")
    check(r.runSeconds == 19 * 3600 + 12 * 60 + 9, "run time 19:12:09")
    check(r.backlight == 60, "backlight")
    check(r.deviceType == 2, "DC device")
} else { check(false, "real status frame decodes") }

var bad = capture; bad[20] ^= 1
check(StatusReport(frame: bad) == nil, "bad checksum rejected")

// MARK: Parser with the real BLE fragmentation and interleaving
var p = FrameParser()
check(p.feed(capture[0..<20]).isEmpty, "first fragment waits")
let frames = p.feed(capture[20...])
check(frames.count == 1, "second fragment completes")

let ok = parseHex("ff 55 02 01 01 00 00 40")!, unsupported = parseHex("ff 55 02 01 03 00 00 42")!
let value = parseHex("ca cb 00 9c 21 ce cf")!
var mixed = FrameParser()
let out = mixed.feed(capture + [0x6F] + value + ok + unsupported)
check(out.count == 5, "five interleaved frames")
if out.count == 5 {
    check(out[1].frame == .ack, "ack")
    check(out[2].frame.u24 == 39969, "mAh value")
    check(out[3].frame == .reply(.ok), "OK reply")
    check(out[4].frame == .reply(.unsupported), "unsupported reply")
}

var byByte = FrameParser(); var count = 0
for b in capture + value + ok { count += byByte.feed([b]).count }
check(count == 3, "one byte at a time")

var noisy = FrameParser()
let recovered = noisy.feed([0x00, 0xFF, 0x12, 0xCA, 0x00] + capture)
check(recovered.count == 1, "recovers from noise")
var falseStart = FrameParser()
let fs = falseStart.feed(Array(capture[0..<18]) + capture + capture)
check(fs.filter { if case .status = $0.frame { true } else { false } }.count >= 2, "recovers from a truncated frame")

// MARK: Commands, bytes exactly as sent to and accepted by the real unit
check(Command.setCurrent(0.10).bytes == [0xB1, 0xB2, 0x02, 0x00, 0x0A, 0xB6], "set 0.10 A")
check(Command.setCutoff(4.99).bytes == [0xB1, 0xB2, 0x03, 0x04, 0x63, 0xB6], "set 4.99 V")
check(Command.setCutoff(5.00).bytes == [0xB1, 0xB2, 0x03, 0x05, 0x00, 0xB6], "set 5.00 V")
check(Command.setTimer(seconds: 120).bytes == [0xB1, 0xB2, 0x04, 0x00, 0x78, 0xB6], "timer 120")
check(Command.setLoad(true).bytes == [0xB1, 0xB2, 0x01, 0x01, 0x00, 0xB6], "load on")
check(Command.setLoad(false).bytes == [0xB1, 0xB2, 0x01, 0x00, 0x00, 0xB6], "load off")
check(Command.query(.setCurrent).bytes == [0xB1, 0xB2, 0x17, 0, 0, 0xB6], "query")
check(hexString(Command.button(.ok).bytes) == "ff 55 11 02 32 00 00 00 00 01", "OK button")
check(hexString(Command.button(.setup).bytes) == "ff 55 11 02 31 00 00 00 00 00", "Setup button")
check(hexString(Command.button(.plus).bytes) == "ff 55 11 02 33 00 00 00 00 02", "Plus button")
check(hexString(Command.button(.minus).bytes) == "ff 55 11 02 34 00 00 00 00 03", "Minus button")
check(Command.setCurrent(1.15).bytes[3...4] == [1, 15], "1.15 does not truncate to 1.14")
check(Command.setCurrent(999).bytes[3...4] == [20, 0], "current clamps to range")
check(Command.setCurrent(-1).bytes[3...4] == [0, 0], "negative current clamps")
check(Command.setCutoff(999).bytes[3...4] == [200, 0], "cutoff clamps to range")
check(parseHex("B1 B2 17 00 00 B6") == [0xB1, 0xB2, 0x17, 0, 0, 0xB6], "hex parse")
check(parseHex("B1 B") == nil && parseHex("zz") == nil && parseHex("") == nil, "bad hex rejected")
check(Command.raw([0xB1, 0xB2, 0x17, 0, 0, 0xB6]).expected == .value, "raw query expects value")
check(Command.raw([0xB1, 0xB2, 0x02, 0, 1, 0xB6]).expected == .ack, "raw set expects ack")

// MARK: Regulator
check(near(Regulator.current(mode: .cc, target: 3, voltage: 0, previous: 0, limit: 5), 3), "CC is the setpoint")
check(near(Regulator.current(mode: .cc, target: 9, voltage: 12, previous: 0, limit: 5), 5), "CC respects limit")
check(near(Regulator.current(mode: .cp, target: 10, voltage: 10, previous: 1, limit: 5), 1), "CP steady state")
check(near(Regulator.current(mode: .cp, target: 100, voltage: 10, previous: 0, limit: 5), 0.5), "CP slew limited")
check(near(Regulator.current(mode: .cp, target: 100, voltage: 10, previous: 4.9, limit: 5), 5), "CP clamps to limit")
check(Regulator.current(mode: .cp, target: 100, voltage: 0.1, previous: 3, limit: 5) == 0, "CP refuses low voltage")
check(near(Regulator.current(mode: .cr, target: 2, voltage: 10, previous: 5, limit: 6), 5), "CR steady state")
check(Regulator.current(mode: .cr, target: 0, voltage: 10, previous: 5, limit: 6) == 0, "CR zero ohms is zero amps")

// MARK: Guards
func sample(t: Double, v: Double = 12, i: Double = 1, set: Double = 1, temp: Double = 30, on: Bool = true) -> Sample {
    Sample(t: t, voltage: v, current: i, milliampHours: 0, milliwattHours: 0, temperatureC: temp, setCurrent: set, loadOn: on)
}
var stops = StopConditions(); stops.cutoffV = 10
func firstStop(_ g: inout GuardEngine, _ make: (Double) -> Sample) -> StopReason? {
    for k in 0..<30 { if let r = g.evaluate(make(1 + Double(k) * 0.1), capacityAh: 0) { return r } }
    return nil
}
var g = GuardEngine(stops: stops)
check(firstStop(&g) { sample(t: $0) } == nil, "normal running does not stop")
g = GuardEngine(stops: stops)
if case .overshoot = firstStop(&g, { sample(t: $0, i: 8, set: 1) }) {} else { check(false, "CV or CR panel mode overshoot stops the load") }
g = GuardEngine(stops: stops)
check(firstStop(&g) { sample(t: $0, v: 9.5) } == .cutoff, "cutoff")
g = GuardEngine(stops: stops)
check(firstStop(&g) { sample(t: $0, temp: 80) } == .temperature, "temperature")
g = GuardEngine(stops: stops)
check(firstStop(&g) { sample(t: $0, v: 200, i: 1) } == .power, "power")
g = GuardEngine(stops: stops)
check(g.evaluate(sample(t: 0, v: 9), capacityAh: 0) == nil && g.evaluate(sample(t: 0.1, v: 12), capacityAh: 0) == nil
      && g.evaluate(sample(t: 0.2, v: 9), capacityAh: 0) == nil && g.evaluate(sample(t: 0.3, v: 9), capacityAh: 0) == nil,
      "a single noisy sample does not trip")
g = GuardEngine(stops: stops)
check(firstStop(&g) { sample(t: $0, v: 9, on: false) } == nil, "guards idle while load is off")
g = GuardEngine(stops: stops)
_ = g.evaluate(sample(t: 0, i: 5, set: 5), capacityAh: 0)
check(g.evaluate(sample(t: 0.1, i: 5, set: 1), capacityAh: 0) == nil && g.evaluate(sample(t: 0.2, i: 5, set: 1), capacityAh: 0) == nil
      && g.evaluate(sample(t: 0.3, i: 4, set: 1), capacityAh: 0) == nil, "lowering the setpoint has a grace period")

g = GuardEngine(stops: stops)
check(g.evaluate(sample(t: 0, i: 0.3, set: 0.1), capacityAh: 0) == nil && g.evaluate(sample(t: 0.05, i: 0.3, set: 0.1), capacityAh: 0) == nil
      && g.evaluate(sample(t: 0.1, i: 0.3, set: 0.1), capacityAh: 0) != nil, "no grace period at load-on: mild overshoot trips on the third sample")
g = GuardEngine(stops: stops)
check(g.evaluate(sample(t: 0, i: 30, set: 0.3), capacityAh: 0) != nil, "severe overshoot trips on the first sample")
g = GuardEngine(stops: stops)
_ = g.evaluate(sample(t: 0, i: 5, set: 5), capacityAh: 0)
check(g.evaluate(sample(t: 0.1, i: 5, set: 1), capacityAh: 0) == nil, "severe check still allows settling after lowering a setpoint")
g = GuardEngine(stops: stops)
_ = g.evaluate(sample(t: 0, i: 1, set: 1), capacityAh: 0)
check(g.evaluate(sample(t: 0.1, i: 1, set: 5), capacityAh: 0) == nil, "raising a setpoint does not trip")

// MARK: Programs
let irProgram = TestProgram.templates.first { $0.kind == .internalResistance }!
check(irProgram.totalDuration == 140, "IR takes 2:20")
check(near(irProgram.plannedAh!, 410.0 / 3600), "IR planned capacity")
var run = ProgramRun(program: irProgram)
var actions = run.start(at: 0)
check(actions == [.loadOff], "IR starts with a rest")
actions = run.tick(sample(t: 19.9, i: 0, on: false)); check(actions.isEmpty, "still resting")
actions = run.tick(sample(t: 20, i: 0, on: false)); check(actions == [.setCurrent(2), .loadOn], "enters first hold")
actions = run.tick(sample(t: 50, v: 13, i: 2, set: 2)); check(actions == [.loadOff], "rest again")
actions = run.tick(sample(t: 70, v: 13.1, i: 0, on: false)); check(actions == [.setCurrent(5), .loadOn], "5 A")
actions = run.tick(sample(t: 100, v: 13.000, i: 5, set: 5)); check(actions == [.setCurrent(10), .loadOn], "10 A")
actions = run.tick(sample(t: 120, v: 12.941, i: 10, set: 10)); check(actions == [.loadOff], "final rest")
actions = run.tick(sample(t: 140, v: 13.05, i: 0, on: false)); check(actions == [.loadOff, .finished(.finished)], "finishes with load off")
check(run.isFinished, "finished flag")
check(near(ProgramResult.dcResistance(run.results)!, 0.0118, 0.0001), "DC resistance is 11.8 mΩ")

var aborted = ProgramRun(program: irProgram)
_ = aborted.start(at: 0)
check(aborted.abort(.temperature) == [.loadOff, .finished(.temperature)], "abort turns the load off")
check(aborted.tick(sample(t: 999)).isEmpty, "no actions after finishing")

var open = ProgramRun(program: TestProgram.templates[0])
check(open.start(at: 0) == [.setCurrent(5), .loadOn], "capacity holds")
check(open.tick(sample(t: 90000, i: 5, set: 5)).isEmpty, "open-ended step only ends on a stop")

// MARK: Analysis and CSV
var ramp: [Sample] = []
for k in 0...100 {
    let x = Double(k)
    ramp.append(Sample(t: x, voltage: 13 - x * 0.01, current: 5, milliampHours: x * 10,
                       milliwattHours: x * 120, temperatureC: 30 + x * 0.1, setCurrent: 5, loadOn: true))
}
let sum = SessionSummary(samples: ramp)
check(near(sum.capacityAh, 1) && near(sum.energyWh, 12), "summary uses counters")
check(near(sum.maxVoltage, 13) && near(sum.minVoltage, 12), "voltage range")
check(near(sum.peakTemperature, 40), "peak temperature")
check(near(sum.meanVoltage, 12), "mean voltage")
var brief: [Sample] = []
for k in 0...60 {
    brief.append(Sample(t: Double(k), voltage: 9, current: 0.3, milliampHours: 39977, milliwattHours: 289700,
                        temperatureC: 27, setCurrent: 0.3, loadOn: true))
}
let briefSummary = SessionSummary(samples: brief)
check(near(briefSummary.capacityAh, 0.005, 0.0001) && near(briefSummary.energyWh, 0.045, 0.0001), "short tests add up samples, matching the real 0.005 Ah run")
let small = downsample(ramp, limit: 20)
check(small.count <= 22 && small.first == ramp.first && small.last == ramp.last, "downsample keeps endpoints")
check(downsample(ramp, limit: 1000).count == ramp.count, "no downsample under limit")
let line = SampleCSV.row(ramp[10])
let parsed = SampleCSV.parse(line: Substring(line))!
check(near(parsed.voltage, ramp[10].voltage) && parsed.loadOn && near(parsed.setCurrent, 5), "CSV round trip")
check(SampleCSV.parse(line: "garbage") == nil, "CSV rejects garbage")
check(SampleCSV.parse(line: Substring(SampleCSV.row(sample(t: 1, i: 0)))) != nil, "CSV handles empty resistance")

// MARK: Simulator speaks the real protocol, end to end through the parser
let sim = SimulatedDL24()
func ask(_ c: Command) -> [ParsedFrame] { var parser = FrameParser(); return parser.feed(sim.receive(c.bytes)) }
check(StatusReport(frame: sim.statusFrame()) != nil, "sim status frame is valid")
check(ask(.setCurrent(1.5)).first?.frame == .ack, "sim acks set")
check(ask(.query(.setCurrent)).first?.frame.u24 == 150, "sim reads back")
_ = ask(.setLoad(true))
check(ask(.query(.load)).first?.frame.u24 == 1, "sim load on")
sim.advance(3600)
check(near(sim.milliampHours, 1500, 1), "sim integrates capacity")
let timed = SimulatedDL24()
_ = timed.receive(Command.setTimer(seconds: 120).bytes)
_ = timed.receive(Command.setLoad(true).bytes)
timed.advance(70)
check(timed.timerSeconds == 60 && timed.loadOn, "timer counts down in minutes while running, as the real unit does")
_ = timed.receive(Command.setLoad(false).bytes)
timed.advance(300)
check(timed.timerSeconds == 60, "timer holds while the load is off")
_ = timed.receive(Command.setLoad(true).bytes)
timed.advance(60)
check(!timed.loadOn && timed.timerSeconds == 0, "timer stops the load at zero and turns itself off")
let noSource = SimulatedDL24(); noSource.sourceConnected = false
_ = noSource.receive(Command.setLoad(true).bytes)
check(noSource.loadOn == false, "no source stays off, matching the real unit")
check(sim.receive([0xFF, 0x55, 0x11, 0x02, 0x21, 0, 0, 0, 0x1E, 0x16]).count == 8, "sim rejects backlight like the real unit")

// MARK: CC-CV
/// A falling set current must not switch the overshoot check off for good.
g = GuardEngine(stops: stops)
var taperStop: StopReason?
var taperSet = 5.0
for k in 0..<12 where taperStop == nil {
    taperSet -= 0.1
    taperStop = g.evaluate(sample(t: Double(k) * 0.5, i: 8, set: taperSet), capacityAh: 0)
}
if case .overshoot = taperStop {} else { check(false, "overshoot still trips while the setting keeps falling every 0.5 s") }
g = GuardEngine(stops: stops)
_ = g.evaluate(sample(t: 0, i: 5, set: 5), capacityAh: 0)
check(g.evaluate(sample(t: 0.1, i: 30, set: 4.75), capacityAh: 0) != nil, "a far overshoot trips even while the setting settles")

protocol CCCVSource: AnyObject {
    var voltage: Double { get }
    var current: Double { get }
    var setCurrent: Double { get }
    var loadOn: Bool { get }
    var temperature: Double { get }
    func write(_ amps: Double)
    func advance(_ dt: Double)
}

/// Repeatable noise, so a failing check fails the same way every run.
struct Noise {
    var state: UInt64
    mutating func next(_ amplitude: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 40) / Double(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}

/// A battery with series resistance, slow relaxation and a falling voltage curve,
/// read through a meter with noise and 1 mV and 1 mA steps.
final class BatteryModel: CCCVSource {
    var fullVolts = 4.1, emptyVolts = 3.0, capacityAh = 1.0
    var seriesOhm = 0.1, relaxOhm = 0.05, relaxSeconds = 40.0
    var noiseVolts = 0.003, noiseAmps = 0.002
    var setCurrent = 0.0, loadOn = true, temperature = 30.0
    var isConnected = true
    private var removedAh = 0.0, relaxVolts = 0.0
    private var noise = Noise(state: 42)

    var trueCurrent: Double { loadOn && isConnected ? setCurrent : 0 }
    var trueVoltage: Double {
        guard isConnected else { return 0 }
        let fraction = min(removedAh / capacityAh, 1.2)
        let ocv = fullVolts - (fullVolts - emptyVolts) * fraction
        return max(0, ocv - trueCurrent * seriesOhm - relaxVolts)
    }
    var voltage: Double { ((trueVoltage + noise.next(noiseVolts)) * 1000).rounded() / 1000 }
    var current: Double { max(0, ((trueCurrent + noise.next(noiseAmps)) * 1000).rounded() / 1000) }
    func write(_ amps: Double) { setCurrent = amps }
    func advance(_ dt: Double) {
        removedAh += trueCurrent * dt / 3600
        relaxVolts += (trueCurrent * relaxOhm - relaxVolts) * min(1, dt / relaxSeconds)
    }
}

/// SimulatedDL24 driven only through its byte protocol, as the app drives a real unit.
final class SimulatedSource: CCCVSource {
    let sim: SimulatedDL24
    init(_ sim: SimulatedDL24) { self.sim = sim }
    private func read(_ q: Query) -> Double {
        var parser = FrameParser()
        return Double(parser.feed(sim.receive(Command.query(q).bytes)).first?.frame.u24 ?? 0)
    }
    var voltage: Double { read(.millivolts) / 1000 }
    var current: Double { read(.milliamps) / 1000 }
    var setCurrent: Double { read(.setCurrent) / 100 }
    var loadOn: Bool { read(.load) == 1 }
    var temperature: Double { sim.temperature }
    func write(_ amps: Double) { _ = sim.receive(Command.setCurrent(amps).bytes) }
    func advance(_ dt: Double) { sim.advance(dt) }
}

struct CCCVTrace {
    var writes: [(t: Double, amps: Double)] = []
    var cvStart: (t: Double, voltage: Double)?
    var stop: StopReason?
    var deviceStopped = false
    var cvSetAtStart = 0.0
    var ccSets: [Double] = []
    var cvVoltages: [Double] = []
    var endT = 0.0
    var finalCurrent = 0.0
    /// Direction changes in the writes once CV has begun. The ramp up to the CC
    /// current ending in the first lowering is not hunting.
    var reversals: Int {
        var count = 0, direction = 0
        let cv = writes.filter { $0.t >= (cvStart?.t ?? .infinity) }
        for (a, b) in zip(cv, cv.dropFirst()) where b.amps != a.amps {
            let d = b.amps > a.amps ? 1 : -1
            if direction != 0, d != direction { count += 1 }
            direction = d
        }
        return count
    }
}

/// The same order as the app's poll loop: read, guards first, then the regulator,
/// with polling paused during a write. Writes before this are the load-on start.
func runCCCV(_ source: CCCVSource, _ settings: CCCVSettings, stops: StopConditions = StopConditions(),
             poll: Double = 0.25, hours: Double = 8, each: ((Double) -> Void)? = nil) -> CCCVTrace {
    var trace = CCCVTrace()
    var regulator = CCCVRegulator(settings: settings)
    var guards = GuardEngine(stops: stops)
    let start = CCCVRegulator.startCurrent(settings: settings, voltage: source.voltage)
    source.write(start)
    trace.writes.append((t: 0, amps: start))
    var t = 0.0
    while t < hours * 3600 {
        each?(t)
        source.advance(poll)
        t += poll
        guard source.loadOn else { trace.deviceStopped = true; break }
        let v = source.voltage, i = source.current, set = source.setCurrent
        let s = Sample(t: t, voltage: v, current: i, milliampHours: 0, milliwattHours: 0,
                       temperatureC: source.temperature, setCurrent: set, loadOn: true)
        if let reason = guards.evaluate(s, capacityAh: 0) { trace.stop = reason; trace.finalCurrent = i; break }
        let action = regulator.update(t: t, voltage: v, current: i, setCurrent: set)
        if regulator.phase == .constantVoltage {
            if trace.cvStart == nil { trace.cvStart = (t: t, voltage: v); trace.cvSetAtStart = set }
            trace.cvVoltages.append(v)
        } else {
            trace.ccSets.append(set)
        }
        if case .stop(let reason) = action { trace.stop = reason; trace.finalCurrent = i; break }
        if case .setCurrent(let amps) = action {
            source.write(amps)
            trace.writes.append((t: t, amps: amps))
            // A verified write holds up polling for about this long.
            source.advance(0.2)
            t += 0.2
        }
    }
    trace.endT = t
    return trace
}

func stepsAreGentle(_ trace: CCCVTrace, settings: CCCVSettings) -> Bool {
    for (a, b) in zip(trace.writes, trace.writes.dropFirst()) {
        if b.t - a.t < Regulator.updateInterval { return false }
        if abs(b.amps - a.amps) > Regulator.maxStepAmps + 0.001 { return false }
    }
    return true
}

func writesStayInRange(_ trace: CCCVTrace, limit: Double) -> Bool {
    trace.writes.allSatisfy { $0.amps >= 0 && $0.amps <= limit }
}

func settled(_ settings: CCCVSettings, v: Double, i: Double, set: Double, from: Double = 100, count: Int = 8) -> (CCCVRegulator, Double) {
    var r = CCCVRegulator(settings: settings)
    var t = from
    for _ in 0..<count { _ = r.update(t: t, voltage: v, current: i, setCurrent: set); t += 0.25 }
    return (r, t)
}

// The whole run on a typical cell.
var cellStops = StopConditions(); cellStops.cutoffV = 3.0
let cellSettings = CCCVSettings(current: 1.15, targetVoltage: 3.6, endCurrent: 0.1)
let cell = BatteryModel()
let cellRun = runCCCV(cell, cellSettings, stops: cellStops)
check(cellRun.writes.first!.amps <= 0.12, "CC-CV starts low and ramps up")
check(cellRun.writes.contains { $0.amps == 1.15 }, "ramp reaches the CC current exactly, without truncating 1.15 to 1.14")
let ccHeld = cellRun.ccSets.drop { $0 < 1.15 }
check(ccHeld.count > 1000 && ccHeld.allSatisfy { $0 == 1.15 }, "CC phase holds the current")
check(near(cellRun.cvSetAtStart, 1.15), "stays at the CC current until the target")
if let cv = cellRun.cvStart {
    check(near(cv.voltage, 3.6, 0.03), "CV begins at the target voltage")
} else { check(false, "CV phase begins") }
check(cellRun.cvVoltages.dropFirst(10).allSatisfy { near($0, 3.6, 0.06) }, "CV holds the target voltage")
let cvWrites = cellRun.writes.filter { $0.t >= (cellRun.cvStart?.t ?? 0) }
check(cvWrites.count > 10 && cvWrites.last!.amps < 0.15, "current tapers through CV")
check(cvWrites.first!.amps > cvWrites[cvWrites.count / 2].amps && cvWrites[cvWrites.count / 2].amps > cvWrites.last!.amps, "the taper keeps falling")
if case .endCurrentReached = cellRun.stop {} else { check(false, "finishes at the end current") }
check(cellRun.stop?.isNormalFinish == true, "the finish reads as normal")
check(cellRun.finalCurrent <= 0.125, "finish is at the end current")
check(!cellRun.deviceStopped, "the cutoff below the target stays out of the way")
check(writesStayInRange(cellRun, limit: 1.15), "never writes above the CC current or below 0")
check(stepsAreGentle(cellRun, settings: cellSettings), "writes respect the rate limit and step bound")

// Stable on any source: a thousandfold range of resistance, with and without relaxation.
for ohm in [0.012, 0.05, 0.2, 0.5, 1.0, 2.0, 5.0, 12.0] {
    for relax in [0.0, 0.1, 0.5] {
        let b = BatteryModel()
        b.fullVolts = 13; b.emptyVolts = 10; b.capacityAh = 0.5
        b.seriesOhm = ohm; b.relaxOhm = relax
        b.noiseVolts = 0.005
        var bStops = StopConditions(); bStops.cutoffV = 8
        // Enough current to sag well, but not more than the source can give.
        let amps = min(2, 2.5 / ohm)
        let settings = CCCVSettings(current: amps, targetVoltage: 11, endCurrent: amps * 0.1)
        let r = runCCCV(b, settings, stops: bStops)
        let label = "R \(ohm) Ω, relax \(relax) Ω"
        let settledVolts = r.cvVoltages.dropFirst(10)
        check(settledVolts.allSatisfy { near($0, 11, 0.15) }, "voltage stays near the target: \(label)")
        check(r.stop?.isNormalFinish == true, "finishes normally: \(label)")
        check(r.reversals <= 4, "no sustained oscillation (\(r.reversals) reversals): \(label)")
        check(writesStayInRange(r, limit: amps), "stays in range: \(label)")
        check(stepsAreGentle(r, settings: settings), "gentle: \(label)")
    }
}

// Meter noise must not walk the current down on a source that is at the target.
// Noise well beyond this range can still taper early, which ends a run sooner.
for amplitude in [0.005, 0.015, 0.03] {
    var (r, t0) = settled(CCCVSettings(current: 2, targetVoltage: 11, endCurrent: 0.2), v: 11, i: 2, set: 2)
    var set = 2.0
    var n = Noise(state: 11)
    for k in 0..<7200 {
        let action = r.update(t: t0 + Double(k) * 0.25, voltage: 11 + n.next(amplitude), current: set, setCurrent: set)
        if case .setCurrent(let a) = action { set = a }
    }
    check(set >= 1.8, "30 minutes of ±\(amplitude) V noise leaves the current alone, got \(set) A")
}

// A steep end of discharge through the real byte protocol, on SimulatedDL24.
let steep = SimulatedDL24()
steep.ratedAh = 2; steep.milliampHours = 1500; steep.cutoff = 10
let steepSource = SimulatedSource(steep)
_ = steep.receive(Command.setLoad(true).bytes)
var steepStops = StopConditions(); steepStops.cutoffV = 10
let steepSettings = CCCVSettings(current: 5, targetVoltage: 11.5, endCurrent: 0.25)
let steepRun = runCCCV(steepSource, steepSettings, stops: steepStops)
check(steepRun.cvStart != nil, "SimulatedDL24 reaches CV")
check(steepRun.stop?.isNormalFinish == true && !steepRun.deviceStopped, "SimulatedDL24 finishes at the end current, with its cutoff unused")
check(steepRun.reversals <= 4, "SimulatedDL24: no sustained oscillation")
check(writesStayInRange(steepRun, limit: 5), "SimulatedDL24: stays in range")
check(stepsAreGentle(steepRun, settings: steepSettings), "SimulatedDL24: gentle")
check(steepRun.cvVoltages.dropFirst(10).allSatisfy { $0 > 11.5 - steepSettings.cutoffMargin * 2 && $0 < 11.6 }, "SimulatedDL24: voltage stays close through the steep knee")

// Guards still act during CC-CV, against the real byte protocol.
func simulatedRun(panel: SimulatedDL24.PanelMode = .cc, stops s: StopConditions, deviceCutoff: Double = 10) -> CCCVTrace {
    let unit = SimulatedDL24()
    unit.ratedAh = 2; unit.milliampHours = 1500; unit.cutoff = deviceCutoff; unit.panelMode = panel
    _ = unit.receive(Command.setLoad(true).bytes)
    return runCCCV(SimulatedSource(unit), CCCVSettings(current: 2, targetVoltage: 11.5, endCurrent: 0.2), stops: s)
}
var guardStops = StopConditions(); guardStops.cutoffV = 10
if case .overshoot = simulatedRun(panel: .cr(1), stops: guardStops).stop {} else { check(false, "CC-CV: a panel left in CR trips overshoot") }
if case .overshoot = simulatedRun(panel: .cv(11.5), stops: guardStops).stop {} else { check(false, "CC-CV: a panel left in CV trips overshoot") }
var hotStops = guardStops; hotStops.temperatureC = 25
check(simulatedRun(stops: hotStops).stop == .temperature, "CC-CV: temperature guard")
var powerStops = guardStops; powerStops.powerW = 1
check(simulatedRun(stops: powerStops).stop == .power, "CC-CV: power guard")
var highStops = guardStops; highStops.cutoffV = 12.5
check(simulatedRun(stops: highStops).stop == .cutoff, "CC-CV: the app's cutoff guard still acts")
let earlyRun = simulatedRun(stops: guardStops, deviceCutoff: 11.8)
check(earlyRun.deviceStopped && earlyRun.cvStart == nil, "a DL24P cutoff above the target stops the load before CV, which is why the app warns")

// A collapse with the guard off must not read as a normal finish.
let lost = BatteryModel(); lost.capacityAh = 50
var lostStops = StopConditions(); lostStops.cutoffEnabled = false
let lostRun = runCCCV(lost, CCCVSettings(current: 1, targetVoltage: 3.6, endCurrent: 0.1), stops: lostStops, hours: 1) { t in
    if t > 60 { lost.isConnected = false }
}
if case .cvVoltageLost = lostRun.stop {} else { check(false, "losing the source reads as a problem") }
check(lostRun.stop?.isNormalFinish == false, "losing the source is not a normal finish")

// One wrong reading, as the DL24P is known to give, changes nothing.
let plain = CCCVSettings(current: 2, targetVoltage: 3.6, endCurrent: 0.2)
var (ccReg, ccT) = settled(plain, v: 3.8, i: 2, set: 2)
check(ccReg.phase == .constantCurrent, "stays in CC above the target")
check(ccReg.update(t: ccT, voltage: 0.5, current: 2, setCurrent: 2) == .hold, "one low voltage reading writes nothing")
check(ccReg.update(t: ccT + 0.25, voltage: 3.8, current: 2, setCurrent: 2) == .hold && ccReg.phase == .constantCurrent, "one low voltage reading does not start CV")
var (cvReg, cvT) = settled(plain, v: 3.6, i: 1, set: 1)
check(cvReg.phase == .constantVoltage, "at the target it is in CV")
var sawStop = false
for k in 0..<40 {
    let i = k % 8 == 0 ? 0.002 : 1.0
    if case .stop = cvReg.update(t: cvT + Double(k) * 0.25, voltage: 3.6, current: i, setCurrent: 1) { sawStop = true }
}
check(!sawStop, "a wrong low current reading does not finish the run")
var (wobbleReg, wobbleT) = settled(plain, v: 3.6, i: 1, set: 1)
var wobbleWrites = 0
var wobble = Noise(state: 7)
for k in 0..<2000 {
    let v = 3.6 + wobble.next(0.01)
    if case .setCurrent = wobbleReg.update(t: wobbleT + Double(k) * 0.25, voltage: v, current: 1, setCurrent: 1) { wobbleWrites += 1 }
}
check(wobbleWrites == 0, "noise inside the band writes nothing")

// The limit comes first, whatever put the setting above it.
var overLimit = CCCVRegulator(settings: plain)
check(overLimit.update(t: 0, voltage: 3.8, current: 5, setCurrent: 5) == .setCurrent(2), "a setting above the CC current is lowered at once")
check(overLimit.update(t: 0.1, voltage: 3.8, current: 5, setCurrent: 5) == .hold, "that still respects the rate limit")
var (lowered, loweredT) = settled(plain, v: 3.8, i: 2, set: 2)
lowered.settings.current = 1.5
check(lowered.update(t: loweredT, voltage: 3.8, current: 2, setCurrent: 2) == .setCurrent(1.5), "lowering the CC current mid-run applies")
var (floorReg, floorT) = settled(plain, v: 3.0, i: 0.01, set: 0.01)
check(floorReg.update(t: floorT, voltage: 3.0, current: 0.01, setCurrent: 0.01) == .setCurrent(0), "current stops at zero")
check(floorReg.update(t: floorT + 1, voltage: 3.0, current: 0, setCurrent: 0) == .hold, "and never goes below it")
check(CCCVRegulator.startCurrent(settings: plain, voltage: 3.0) == 0, "no current to start with at or below the target")

// Settings problems
let good = CCCVSettings(current: 2, targetVoltage: 3.6, endCurrent: 0.2)
check(good.issues(cutoff: 3.0, inputVoltage: 4).isEmpty, "good settings raise nothing")
let aboveIssues = good.issues(cutoff: 3.7, inputVoltage: 4)
check(aboveIssues == [.cutoffAtOrAboveTarget(cutoff: 3.7, target: 3.6)] && !aboveIssues[0].blocksStart, "cutoff above the target warns")
check(good.issues(cutoff: 3.6, inputVoltage: 4).first == .cutoffAtOrAboveTarget(cutoff: 3.6, target: 3.6), "cutoff at the target warns")
check(good.issues(cutoff: 3.55, inputVoltage: 4).first == .cutoffCloseToTarget(cutoff: 3.55, target: 3.6), "cutoff just below the target warns")
check(good.issues(cutoff: 3, inputVoltage: 3.5).first?.blocksStart == true, "input below the target blocks the start")
check(good.issues(cutoff: 3, inputVoltage: nil).isEmpty, "the input check is off once running, when the source sags")
check(CCCVSettings(current: 1, targetVoltage: 3.6, endCurrent: 1).issues(cutoff: 3, inputVoltage: 4) == [.invalidEndCurrent], "end current must be below the CC current")
check(CCCVSettings(current: 1, targetVoltage: 3.6, endCurrent: 0).issues(cutoff: 3, inputVoltage: 4) == [.invalidEndCurrent], "end current must be above zero")
check(CCCVSettings(current: 1, targetVoltage: 0, endCurrent: 0.1).issues(cutoff: 0, inputVoltage: 4).contains(.invalidTarget), "target must be above zero")

// Stop reasons survive a saved session and read correctly.
let finishedReason = StopReason.endCurrentReached(current: 0.1)
let savedReason = try! JSONDecoder().decode(StopReason.self, from: JSONEncoder().encode(finishedReason))
check(savedReason == finishedReason, "the finish round-trips through a saved session")
check(finishedReason.title == "CC-CV finished" && StopReason.finished.isNormalFinish, "the finish title")
check(!StopReason.cutoff.isNormalFinish && !StopReason.overshoot(current: 1, set: 1).isNormalFinish, "problems are not finishes")
check(near(Regulator.current(mode: .cccv, target: 3, voltage: 12, previous: 0, limit: 2), 2), "the shared regulator clamps CC-CV to its limit")

// A write can land well after it was asked for, and settling starts when it lands.
do {
    var r = CCCVRegulator(settings: CCCVSettings(current: 1, targetVoltage: 12, endCurrent: 0.1))
    var firstWrite: Double?
    var t = 0.0
    while t < 5, firstWrite == nil {
        if case .setCurrent = r.update(t: t, voltage: 11, current: 1, setCurrent: 1) { firstWrite = t }
        t += 0.07
    }
    check(firstWrite != nil, "a low voltage lowers the current")
    let landed = (firstWrite ?? 0) + 0.45
    r.writeApplied(at: landed)
    var earlyAction = false
    var later = landed + 0.01
    while later < landed + 0.29 {
        if r.update(t: later, voltage: 11, current: 0.9, setCurrent: 0.9) != .hold { earlyAction = true }
        later += 0.07
    }
    check(!earlyAction, "no decision before a landed write has settled")
    var acted = false
    while later < landed + 2, !acted {
        if r.update(t: later, voltage: 11, current: 0.9, setCurrent: 0.9) != .hold { acted = true }
        later += 0.07
    }
    check(acted, "regulation resumes once a landed write has settled")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
