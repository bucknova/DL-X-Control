import Foundation

/// Software stand-in for a DL24P. It speaks the real byte protocol, so it
/// exercises the parser and controller in Demo mode and in the checks.
public final class SimulatedDL24 {
    public enum PanelMode { case cc, cv(Double), cr(Double) }

    public var panelMode: PanelMode = .cc
    public var sourceConnected = true
    public var loadOn = false
    public var setCurrent = 5.0
    public var cutoff = 10.5
    public var timerSeconds = 0
    private var timerRemaining = 0.0
    public var milliampHours = 0.0
    public var milliwattHours = 0.0
    public var runSeconds = 0.0
    public var temperature = 25.0
    public var ratedAh = 20.0
    public var internalOhm = 0.012

    public init() {}

    public var openCircuitVoltage: Double {
        guard sourceConnected else { return 0 }
        let f = milliampHours / 1000 / ratedAh
        return 13.2 - 0.30 * f + 0.75 * exp(-f * 30) - 2.2 * exp((f - 0.92) * 42)
    }

    public var current: Double {
        guard loadOn, sourceConnected else { return 0 }
        let ocv = openCircuitVoltage
        switch panelMode {
        case .cc: return ocv > 0.5 ? setCurrent : 0
        case .cv(let v): return max(0, (ocv - v) / internalOhm)
        case .cr(let r): return ocv / (r + internalOhm)
        }
    }

    public var voltage: Double { max(0, openCircuitVoltage - current * internalOhm) }

    public func advance(_ dt: Double) {
        let i = current, v = voltage
        if loadOn {
            milliampHours += i * dt / 3.6
            milliwattHours += v * i * dt / 3.6
            runSeconds += dt
            if v <= cutoff && i > 0 { loadOn = false }
            // Like the real unit: counts down while running, stops at zero, then reads off.
            if timerRemaining > 0 {
                timerRemaining -= dt
                if timerRemaining <= 0 { timerRemaining = 0; timerSeconds = 0; loadOn = false }
                else { timerSeconds = Int((timerRemaining / 60).rounded(.up)) * 60 }
            }
        }
        let target = 25 + v * i * 0.38
        temperature += (target - temperature) * min(1, dt / 300)
    }

    private func value(_ n: Int) -> [UInt8] {
        [0xCA, 0xCB, UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255), 0xCE, 0xCF]
    }
    private func hms(_ s: Int) -> [UInt8] { [0xCA, 0xCB, UInt8(min(s / 3600, 255)), UInt8(s / 60 % 60), UInt8(s % 60), 0xCE, 0xCF] }
    private func reply(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x02, 0x01, code, 0, 0]
        return [0xFF, 0x55] + body + [dl24Checksum(body)]
    }

    /// Handles one command and returns the device's reply bytes.
    public func receive(_ b: [UInt8]) -> [UInt8] {
        if b.count == 6, b[0] == 0xB1, b[1] == 0xB2, b[5] == 0xB6 {
            let a = Int(b[3]), c = Int(b[4])
            switch b[2] {
            case 0x01:
                loadOn = a == 1 && sourceConnected
                return [0x6F]
            case 0x02: setCurrent = Double(a * 100 + c) / 100; return [0x6F]
            case 0x03: cutoff = Double(a * 100 + c) / 100; return [0x6F]
            case 0x04:
                let s = a << 8 | c
                timerSeconds = s / 60 * 60
                timerRemaining = Double(timerSeconds)
                return [0x6F]
            case 0x05: milliampHours = 0; milliwattHours = 0; runSeconds = 0; return [0x6F]
            case 0x10: return value(loadOn ? 1 : 0)
            case 0x11: return value(Int((voltage * 1000).rounded()))
            case 0x12: return value(Int((current * 1000).rounded()))
            case 0x13: return hms(Int(runSeconds))
            case 0x14: return value(Int(milliampHours))
            case 0x15: return value(Int(milliwattHours))
            case 0x16: return value(Int(temperature))
            case 0x17: return value(Int((setCurrent * 100).rounded()))
            case 0x18: return value(Int((cutoff * 100).rounded()))
            case 0x19: return hms(timerSeconds)
            default: return []
            }
        }
        if b.count == 10, b[0] == 0xFF, b[1] == 0x55, b[2] == 0x11, dl24Checksum(b[2..<9]) == b[9] {
            switch b[4] {
            case 0x01: milliwattHours = 0; return reply(1)
            case 0x02: milliampHours = 0; return reply(1)
            case 0x03: runSeconds = 0; return reply(1)
            case 0x05: milliwattHours = 0; milliampHours = 0; runSeconds = 0; return reply(1)
            case 0x31, 0x33, 0x34: return reply(1)
            case 0x32: if sourceConnected { loadOn.toggle() }; return reply(1)
            default: return reply(3)
            }
        }
        return []
    }

    public func statusFrame() -> [UInt8] {
        func be(_ n: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8((n >> ($0 * 8)) & 255) } }
        let r = Int(runSeconds)
        let body: [UInt8] = [0x01, 0x02]
            + be(Int((voltage * 10).rounded()), 3) + be(Int((current * 1000).rounded()), 3)
            + be(Int(milliampHours / 10), 3) + be(Int(milliwattHours / 10000), 4)
            + [0, 0, 0] + [0, 0, 0, 0]
            + be(Int(temperature), 2) + be(r / 3600, 2) + [UInt8(r / 60 % 60), UInt8(r % 60), 60]
            + [0, 0, 0, 0]
        return [0xFF, 0x55] + body + [dl24Checksum(body)]
    }
}
