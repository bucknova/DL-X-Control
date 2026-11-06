import Foundation

// Wire protocol of the ATORCH DL24P. Two command families share one link:
//   FF 55  periodic status reports, button and counter commands (checksummed)
//   B1 B2  setpoints, load switching and queries (no checksum, FIFO replies)
// Everything here was checked against a real unit over Bluetooth and USB,
// except where a comment says otherwise.

public func dl24Checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
    UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) }) ^ 0x44
}

public struct StatusReport: Equatable, Sendable {
    public let voltage: Double
    public let current: Double
    public let capacityAh: Double
    public let energyWh: Double
    public let temperatureC: Int
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let backlight: Int
    public let deviceType: UInt8

    public var runSeconds: Int { hours * 3600 + minutes * 60 + seconds }

    public init?(frame b: [UInt8]) {
        guard b.count == 36, b[0] == 0xFF, b[1] == 0x55, b[2] == 0x01,
              dl24Checksum(b[2..<35]) == b[35] else { return nil }
        func u(_ range: Range<Int>) -> Int { b[range].reduce(0) { ($0 << 8) | Int($1) } }
        deviceType = b[3]
        voltage = Double(u(4..<7)) / 10
        current = Double(u(7..<10)) / 1000
        capacityAh = Double(u(10..<13)) / 100
        energyWh = Double(u(13..<17)) * 10
        temperatureC = u(24..<26)
        hours = u(26..<28)
        minutes = Int(b[28])
        seconds = Int(b[29])
        backlight = Int(b[30])
    }
}

public enum ReplyStatus: UInt8, Sendable {
    case ok = 1, failed = 2, unsupported = 3
    public var description: String {
        switch self {
        case .ok: "OK"
        case .failed: "Failed"
        case .unsupported: "Unsupported"
        }
    }
}

public enum Frame: Equatable, Sendable {
    case status(StatusReport)
    case reply(ReplyStatus?)
    case value(d1: UInt8, d2: UInt8, d3: UInt8)
    case ack
}

public struct ParsedFrame: Equatable, Sendable {
    public let frame: Frame
    public let raw: [UInt8]
}

/// Incremental parser. A bad frame loses one byte and rescans, so it recovers
/// from a false header found in the middle of a dropped packet.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var discardedBytes = 0

    public init() {}

    public mutating func reset() { buffer.removeAll() }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [ParsedFrame] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var out: [ParsedFrame] = []
        var i = 0
        scan: while i < buffer.count {
            let b0 = buffer[i]
            let left = buffer.count - i
            switch b0 {
            case 0xFF:
                if left < 3 { break scan }
                guard buffer[i + 1] == 0x55 else { i += 1; discardedBytes += 1; continue }
                let length: Int
                switch buffer[i + 2] {
                case 0x01: length = 36
                case 0x02: length = 8
                default: i += 1; discardedBytes += 1; continue
                }
                if left < length { break scan }
                let raw = Array(buffer[i..<(i + length)])
                if length == 36, let report = StatusReport(frame: raw) {
                    out.append(.init(frame: .status(report), raw: raw))
                    i += length
                } else if length == 8, dl24Checksum(raw[2..<7]) == raw[7] {
                    out.append(.init(frame: .reply(ReplyStatus(rawValue: raw[4])), raw: raw))
                    i += length
                } else {
                    i += 1; discardedBytes += 1
                }
            case 0xCA:
                if left < 2 { break scan }
                guard buffer[i + 1] == 0xCB else { i += 1; discardedBytes += 1; continue }
                if left < 7 { break scan }
                let raw = Array(buffer[i..<(i + 7)])
                if raw[5] == 0xCE, raw[6] == 0xCF {
                    out.append(.init(frame: .value(d1: raw[2], d2: raw[3], d3: raw[4]), raw: raw))
                    i += 7
                } else {
                    i += 1; discardedBytes += 1
                }
            case 0x6F:
                out.append(.init(frame: .ack, raw: [0x6F]))
                i += 1
            default:
                i += 1; discardedBytes += 1
            }
        }
        buffer.removeFirst(i)
        return out
    }
}

public enum Query: UInt8, CaseIterable, Sendable {
    case load = 0x10, millivolts = 0x11, milliamps = 0x12, runTime = 0x13
    case milliampHours = 0x14, milliwattHours = 0x15, temperature = 0x16
    case setCurrent = 0x17, cutoff = 0x18, timer = 0x19

    public var label: String {
        switch self {
        case .load: "Read load state"
        case .millivolts: "Read voltage"
        case .milliamps: "Read current"
        case .runTime: "Read run time"
        case .milliampHours: "Read capacity"
        case .milliwattHours: "Read energy"
        case .temperature: "Read temperature"
        case .setCurrent: "Read set current"
        case .cutoff: "Read cutoff"
        case .timer: "Read timer"
        }
    }
}

public enum PanelButton: UInt8, CaseIterable, Sendable {
    case setup = 0x31, ok = 0x32, plus = 0x33, minus = 0x34
    public var label: String {
        switch self {
        case .setup: "Setup"
        case .ok: "OK"
        case .plus: "+"
        case .minus: "−"
        }
    }
}

public enum CounterReset: UInt8, CaseIterable, Sendable {
    // Sent by the vendor app. Not run against the real unit yet, because it
    // erases the stored totals, so the app reports the device's own reply.
    case energy = 0x01, capacity = 0x02, time = 0x03, all = 0x05
    public var label: String {
        switch self {
        case .energy: "Energy"
        case .capacity: "Capacity"
        case .time: "Run time"
        case .all: "All counters"
        }
    }
}

public enum ExpectedReply: Sendable { case ack, value, reply, none }

public enum Command: Sendable, Equatable {
    case query(Query)
    case setLoad(Bool)
    case setCurrent(Double)
    case setCutoff(Double)
    case setTimer(seconds: Int)
    case button(PanelButton)
    case reset(CounterReset)
    case raw([UInt8])

    public static let currentRange: ClosedRange<Double> = 0...20
    public static let cutoffRange: ClosedRange<Double> = 0...200
    public static let maxTimerSeconds = 65535

    /// Encodes as whole units and hundredths, rounding rather than truncating
    /// so 1.15 cannot become 1.14 through floating point error.
    static func hundredths(_ value: Double, in range: ClosedRange<Double>) -> (UInt8, UInt8) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let h = Int((clamped * 100).rounded())
        return (UInt8(h / 100), UInt8(h % 100))
    }

    static func ff55(_ cmd: UInt8, _ v: [UInt8] = [0, 0, 0, 0]) -> [UInt8] {
        let body: [UInt8] = [0x11, 0x02, cmd] + v
        return [0xFF, 0x55] + body + [dl24Checksum(body)]
    }

    public var bytes: [UInt8] {
        switch self {
        case .query(let q): return [0xB1, 0xB2, q.rawValue, 0, 0, 0xB6]
        case .setLoad(let on): return [0xB1, 0xB2, 0x01, on ? 1 : 0, 0, 0xB6]
        case .setCurrent(let a):
            let (w, f) = Self.hundredths(a, in: Self.currentRange)
            return [0xB1, 0xB2, 0x02, w, f, 0xB6]
        case .setCutoff(let v):
            let (w, f) = Self.hundredths(v, in: Self.cutoffRange)
            return [0xB1, 0xB2, 0x03, w, f, 0xB6]
        case .setTimer(let s):
            let c = min(max(s, 0), Self.maxTimerSeconds)
            return [0xB1, 0xB2, 0x04, UInt8(c >> 8), UInt8(c & 0xFF), 0xB6]
        case .button(let b): return Self.ff55(b.rawValue)
        case .reset(let r): return Self.ff55(r.rawValue)
        case .raw(let b): return b
        }
    }

    public var expected: ExpectedReply {
        switch self {
        case .query: return .value
        case .setLoad, .setCurrent, .setCutoff, .setTimer: return .ack
        case .button, .reset: return .reply
        case .raw(let b):
            if b.count >= 3, b[0] == 0xB1, b[1] == 0xB2 { return b[2] >= 0x10 ? .value : .ack }
            if b.count >= 2, b[0] == 0xFF, b[1] == 0x55 { return .reply }
            return .none
        }
    }

    public var label: String {
        switch self {
        case .query(let q): return q.label
        case .setLoad(let on): return on ? "Turn load on" : "Turn load off"
        case .setCurrent(let a): return String(format: "Set current to %.2f A", a)
        case .setCutoff(let v): return String(format: "Set cutoff to %.2f V", v)
        case .setTimer(let s): return s == 0 ? "Turn timer off" : "Set timer to \(s / 60) min"
        case .button(let b): return "Press \(b.label)"
        case .reset(let r): return "Reset \(r.label.lowercased())"
        case .raw: return "Raw command"
        }
    }
}

public func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Parses "B1 B2 17 00 00 B6" or "b1b2170000b6". Returns nil on anything else.
public func parseHex(_ text: String) -> [UInt8]? {
    let clean = text.filter { !$0.isWhitespace }
    guard !clean.isEmpty, clean.count.isMultiple(of: 2), clean.allSatisfy(\.isHexDigit) else { return nil }
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

public extension Frame {
    var u24: Int? {
        if case .value(let a, let b, let c) = self { return Int(a) << 16 | Int(b) << 8 | Int(c) }
        return nil
    }
    /// Query 0x13 and 0x19 return hours, minutes, seconds as separate bytes.
    var hmsSeconds: Int? {
        if case .value(let h, let m, let s) = self { return Int(h) * 3600 + Int(m) * 60 + Int(s) }
        return nil
    }
}
