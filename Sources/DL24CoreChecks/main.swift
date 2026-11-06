import DL24Core
import Foundation

// Runs without Xcode's test tools: `swift run DL24CoreChecks`. Expected bytes
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
let ramp = (0...100).map { Sample(t: Double($0), voltage: 13 - Double($0) * 0.01, current: 5, milliampHours: Double($0) * 10,
                                  milliwattHours: Double($0) * 120, temperatureC: 30 + Double($0) * 0.1, setCurrent: 5, loadOn: true) }
let sum = SessionSummary(samples: ramp)
check(near(sum.capacityAh, 1) && near(sum.energyWh, 12), "summary uses counters")
check(near(sum.maxVoltage, 13) && near(sum.minVoltage, 12), "voltage range")
check(near(sum.peakTemperature, 40), "peak temperature")
check(near(sum.meanVoltage, 12), "mean voltage")
let brief = (0...60).map { Sample(t: Double($0), voltage: 9, current: 0.3, milliampHours: 39977, milliwattHours: 289700, temperatureC: 27, setCurrent: 0.3, loadOn: true) }
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

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
