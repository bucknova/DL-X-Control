import CoreBluetooth
import DL24Core
import Foundation
import Observation

enum LinkState: Equatable {
    case searching
    case verifying(String)
    case connected
    case bluetoothUnavailable(String)
}

enum TransportPreference: String, CaseIterable, Identifiable {
    case auto = "Automatic", usb = "USB", bluetooth = "Bluetooth"
    var id: String { rawValue }
}

struct ConsoleEntry: Identifiable {
    enum Direction: String { case tx = "TX", rx = "RX", info = "··" }
    let id = UUID()
    let time = Date()
    let direction: Direction
    let hex: String
    let note: String
    let isStatus: Bool
}

struct StopBanner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let isProblem: Bool
}

@MainActor @Observable
final class DeviceController {
    // Link
    private(set) var link: LinkState = .searching
    private(set) var transportKind: TransportKind?
    private(set) var deviceName = ""
    private(set) var rssi: Int?
    private(set) var sampleRate = 0.0
    private(set) var linkDrops = 0
    var preference: TransportPreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: "transport")
            if !isDemo { reconnect() }
        }
    }

    // Live values
    private(set) var voltage = 0.0
    private(set) var current = 0.0
    private(set) var milliampHours = 0.0
    private(set) var milliwattHours = 0.0
    private(set) var temperatureC = 0.0
    private(set) var runSeconds = 0
    private(set) var loadOn = false
    private(set) var deviceSetCurrent = 0.0
    private(set) var deviceCutoff = 0.0
    private(set) var deviceTimerSeconds = 0
    private(set) var hasReadSettings = false
    private(set) var loadBusy = false

    // Control
    var mode: ControlMode = .cc { didSet { if oldValue != mode, loadOn { regulatedCurrent = deviceSetCurrent } } }
    var ccTarget = 0.0
    var cpTarget = 10.0
    var crTarget = 10.0
    var currentLimit: Double {
        didSet { UserDefaults.standard.set(currentLimit, forKey: "currentLimit") }
    }
    var stops: StopConditions {
        didSet {
            if let d = try? JSONEncoder().encode(stops) { UserDefaults.standard.set(d, forKey: "stops") }
            if !isRunningProgram { guardEngine.stops = stops }
        }
    }
    var autoRecord: Bool { didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord") } }
    var skipLoadConfirmation = false
    var showLoadConfirmation = false
    var banner: StopBanner?

    // Chart data, published a few times a second to keep the UI cheap
    private(set) var chartSamples: [Sample] = []
    var chartWindow: Double? = nil
    private var live: [Sample] = []
    private var liveStart = Date()
    private var lastChartPublish = Date.distantPast
    private var recordedTimeOffset: Date?

    // Recording and programs
    let store: SessionStore
    private(set) var recorder: SessionRecorder?
    private(set) var recordingName = ""
    private(set) var recordingSeconds = 0.0
    private(set) var recordingSampleCount = 0
    private var stopRecordingAt: Date?
    private var lastStop: StopReason?
    private(set) var run: ProgramRun?
    private(set) var runningProgramID: UUID?
    private var runBaseAh = 0.0
    private var runBaseWh = 0.0
    var isRunningProgram: Bool { run != nil }

    // Console
    private(set) var console: [ConsoleEntry] = []
    private(set) var traffic: [ConsoleEntry] = []
    var showStatusFrames = false

    // Internals
    let isDemo: Bool
    private var transport: Transport?
    private var parser = FrameParser()
    private let central = BluetoothCentral()
    private var discoveryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var verified = false
    private var rejectedPorts: [String: Date] = [:]
    private var bluetoothBlockedByUSB = false
    private var lastTimerSecondsWhileOn = 0
    private var resumeSafeOff = false
    private var guardEngine: GuardEngine
    private var commandedLoad = false
    private var loadBaseMilliampHours = 0.0
    private var regulatedCurrent = 0.0
    private var rateWindow: [Date] = []
    private var demoSim: SimulatedDL24?

    private struct Job { let command: Command; let continuation: CheckedContinuation<ParsedFrame?, Never> }
    private var urgentJobs: [Job] = []
    private var normalJobs: [Job] = []
    private var inFlight: Job?
    private var timeoutTask: Task<Void, Never>?
    private var consecutiveTimeouts = 0
    private var writeTail: Task<Bool, Never>?
    private var lastWrite = Date.distantPast
    private var lastRegulation = Date.distantPast
    private var lastCurrentWrite = Date.distantPast
    private static let writeSpacing = 0.25
    private static let writeAttempts = 3
    private static let regulationInterval = 0.5

    init(store: SessionStore, demo: Bool) {
        self.store = store
        isDemo = demo
        preference = TransportPreference(rawValue: UserDefaults.standard.string(forKey: "transport") ?? "") ?? .auto
        let limit = UserDefaults.standard.object(forKey: "currentLimit") as? Double
        currentLimit = limit ?? 5
        let s = UserDefaults.standard.data(forKey: "stops").flatMap { try? JSONDecoder().decode(StopConditions.self, from: $0) } ?? StopConditions()
        stops = s
        guardEngine = GuardEngine(stops: s)
        autoRecord = UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true

        central.onDiscovered = { [weak self] p, r in self?.discovered(p, rssi: r) }
        central.onState = { [weak self] state in self?.bluetoothStateChanged(state) }

        if demo { startDemo() } else { reconnect() }
    }

    var isConnected: Bool { link == .connected }

    // MARK: Connection

    func reconnect() {
        dropTransport()
        link = .searching
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.transport == nil { self.tryConnect() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// With the USB cable plugged in, Bluetooth can only listen: the two share the
    /// DL24P's serial line, and commands sent over Bluetooth never arrive.
    private static let bluetoothBlockedMessage = "Unplug the DL24P's USB cable to use Bluetooth. While it is plugged in, Bluetooth can read but cannot send commands."

    private func tryConnect() {
        if preference == .bluetooth, bluetoothBlockedByUSB {
            if !SerialDiscovery.candidates().isEmpty {
                link = .bluetoothUnavailable(Self.bluetoothBlockedMessage)
                return
            }
            bluetoothBlockedByUSB = false
            link = .searching
        }
        if preference != .bluetooth {
            let now = Date()
            for path in SerialDiscovery.candidates() where (rejectedPorts[path] ?? .distantPast) < now {
                if let t = SerialTransport(path: path) {
                    central.stopScan()
                    attach(t)
                    return
                }
            }
        }
        if preference != .usb { central.startScan() } else { central.stopScan() }
    }

    private func discovered(_ p: CBPeripheral, rssi r: Int) {
        guard transport == nil, preference != .usb else { return }
        let t = central.connect(p, name: p.name ?? "DL24-BLE")
        rssi = r
        t.onRSSI = { [weak self] v in self?.rssi = v }
        attach(t)
    }

    private func bluetoothStateChanged(_ state: CBManagerState) {
        guard transport == nil else { return }
        switch state {
        case .unauthorized: link = .bluetoothUnavailable("Bluetooth access is off for this app in System Settings.")
        case .poweredOff: link = .bluetoothUnavailable("Bluetooth is turned off.")
        case .poweredOn: if case .bluetoothUnavailable = link { link = .searching }
        default: break
        }
    }

    private func attach(_ t: Transport) {
        transport = t
        parser.reset()
        verified = false
        link = .verifying(t.displayName)
        deviceName = t.displayName
        transportKind = t.kind
        t.onBytes = { [weak self] bytes in self?.received(bytes) }
        t.onClosed = { [weak self] reason in self?.closed(reason) }
        logInfo("Listening on \(t.displayName). Nothing is sent until a DL24 status frame is heard.")
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, !self.verified else { return }
            self.logInfo("No DL24 frames from \(t.displayName). Leaving it alone.")
            if let s = t as? SerialTransport { self.rejectedPorts[s.path] = Date().addingTimeInterval(30) }
            self.dropTransport()
            self.link = .searching
        }
    }

    private func closed(_ reason: String?) {
        let wasRunning = loadOn || commandedLoad
        if verified, wasRunning {
            resumeSafeOff = true
            linkDrops += 1
            recorder?.mark("Connection lost")
        }
        if let reason { logInfo(reason) }
        cleanupLink()
        link = .searching
        if !isDemo { reconnect() }
    }

    private func cleanupLink() {
        pollTask?.cancel(); pollTask = nil
        verifyTask?.cancel(); verifyTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        failAllJobs()
        transport = nil
        transportKind = nil
        rssi = nil
        sampleRate = 0
        verified = false
    }

    private func dropTransport() {
        transport?.close()
        cleanupLink()
    }

    private func failAllJobs() {
        let jobs = (inFlight.map { [$0] } ?? []) + urgentJobs + normalJobs
        inFlight = nil; urgentJobs = []; normalJobs = []
        for j in jobs { j.continuation.resume(returning: nil) }
    }

    // MARK: Receiving

    private func received(_ bytes: [UInt8]) {
        for parsed in parser.feed(bytes) {
            switch parsed.frame {
            case .status(let r):
                logFrame(parsed.raw, note: "Status", isStatus: true)
                if !verified, r.deviceType == 0x02 { becomeVerified() }
                if verified { apply(r) }
            case .ack, .value, .reply:
                resolve(parsed)
            }
        }
    }

    private func becomeVerified() {
        verified = true
        verifyTask?.cancel()
        link = .connected
        discoveryTask?.cancel()
        logInfo("DL24P confirmed on \(deviceName).")
        consecutiveTimeouts = 0
        startPolling()
    }

    private func apply(_ r: StatusReport) {
        // Queries are finer, so a status frame only fills in values when they
        // have not arrived yet, plus the hours field, which the query caps at 255.
        if milliampHours == 0 { milliampHours = r.capacityAh * 1000 }
        if temperatureC == 0 { temperatureC = Double(r.temperatureC) }
        runSeconds = r.runSeconds
    }

    private func resolve(_ parsed: ParsedFrame) {
        guard let job = inFlight else {
            logFrame(parsed.raw, note: "Unexpected reply", isStatus: false)
            return
        }
        let matches: Bool
        switch (job.command.expected, parsed.frame) {
        case (.ack, .ack), (.value, .value), (.reply, .reply): matches = true
        default: matches = false
        }
        guard matches else {
            logFrame(parsed.raw, note: "Unexpected reply", isStatus: false)
            return
        }
        logFrame(parsed.raw, note: describe(parsed.frame, for: job.command), isStatus: isPollQuery(job.command))
        timeoutTask?.cancel()
        inFlight = nil
        consecutiveTimeouts = 0
        job.continuation.resume(returning: parsed)
        pump()
    }

    private func isPollQuery(_ c: Command) -> Bool { if case .query = c { true } else { false } }

    private func describe(_ f: Frame, for c: Command) -> String {
        switch f {
        case .ack: return "Accepted"
        case .reply(let s): return s?.description ?? "Unknown reply"
        case .value:
            guard case .query(let q) = c else { return "Value \(f.u24 ?? 0)" }
            switch q {
            case .load: return f.u24 == 1 ? "Load on" : "Load off"
            case .millivolts: return String(format: "%.3f V", Double(f.u24 ?? 0) / 1000)
            case .milliamps: return String(format: "%.3f A", Double(f.u24 ?? 0) / 1000)
            case .milliampHours: return "\(f.u24 ?? 0) mAh"
            case .milliwattHours: return "\(f.u24 ?? 0) mWh"
            case .temperature: return "\(f.u24 ?? 0) °C"
            case .setCurrent: return String(format: "%.2f A set", Double(f.u24 ?? 0) / 100)
            case .cutoff: return String(format: "%.2f V cutoff", Double(f.u24 ?? 0) / 100)
            case .timer, .runTime: return "\(f.hmsSeconds ?? 0) s"
            }
        case .status: return "Status"
        }
    }

    // MARK: Command bus. Replies carry no ID, so only one is ever outstanding.

    @discardableResult
    func send(_ command: Command, urgent: Bool = false) async -> ParsedFrame? {
        guard transport != nil, verified else { return nil }
        return await withCheckedContinuation { c in
            let job = Job(command: command, continuation: c)
            if urgent { urgentJobs.append(job) } else { normalJobs.append(job) }
            pump()
        }
    }

    private func pump() {
        guard inFlight == nil, let t = transport else { return }
        let job: Job
        if !urgentJobs.isEmpty { job = urgentJobs.removeFirst() }
        else if !normalJobs.isEmpty { job = normalJobs.removeFirst() }
        else { return }
        inFlight = job
        logFrame(job.command.bytes, note: job.command.label, direction: .tx, isStatus: isPollQuery(job.command))
        t.send(job.command.bytes)
        let timeout: Duration = job.command.expected == .none ? .milliseconds(300) : (t.kind == .bluetooth ? .milliseconds(1200) : .milliseconds(400))
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timedOut()
        }
    }

    private func timedOut() {
        guard let job = inFlight else { return }
        inFlight = nil
        parser.reset()
        if job.command.expected != .none {
            consecutiveTimeouts += 1
            logInfo("No reply: \(job.command.label)")
        }
        job.continuation.resume(returning: nil)
        if consecutiveTimeouts >= 3, transportKind == .bluetooth, !SerialDiscovery.candidates().isEmpty {
            // Automatic falls back to USB. Bluetooth-only says what is wrong.
            logInfo("Commands get no reply over Bluetooth while the USB cable is plugged in.")
            if preference == .bluetooth { bluetoothBlockedByUSB = true }
            transport?.close()
            closed("Reconnecting.")
            return
        }
        if consecutiveTimeouts >= 8 {
            logInfo("The DL24P stopped replying.")
            transport?.close()
            closed("Reconnecting.")
            return
        }
        pump()
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func pollLoop() async {
        if resumeSafeOff {
            // The link dropped with the load on. Turn it off before anything else.
            resumeSafeOff = false
            await send(.setLoad(false), urgent: true)
            commandedLoad = false
            finishStop(.linkLost, problem: true)
        }
        await readSettings()
        let slow: [Query] = [.load, .temperature, .load, .milliampHours, .load, .milliwattHours,
                             .load, .setCurrent, .load, .cutoff, .load, .timer, .load, .runTime]
        var slowIndex = 0, round = 0
        while !Task.isCancelled, isConnected {
            let fast = transportKind == .usb || transportKind == .demo
            guard var mv = await send(.query(.millivolts))?.frame.u24, !Task.isCancelled else { continue }
            guard var ma = await send(.query(.milliamps))?.frame.u24, !Task.isCancelled else { continue }
            // The DL24P occasionally reports a wrong value for one reading (seen: 0.487 A
            // and 0.002 A on a steady current, voltage unchanged), and repeats it if asked
            // again right away. So a jump gets a fresh look after a short wait. A real step
            // survives that; a glitch does not.
            if abs(Double(ma) / 1000 - current) > max(0.02, current * 0.1) {
                for _ in 0..<2 {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let again = await send(.query(.milliamps))?.frame.u24 else { break }
                    ma = again
                    if abs(Double(ma) / 1000 - current) <= max(0.02, current * 0.1) { break }
                }
            }
            if abs(Double(mv) / 1000 - voltage) > max(0.05, voltage * 0.02) {
                try? await Task.sleep(for: .milliseconds(80))
                if let again = await send(.query(.millivolts))?.frame.u24 { mv = again }
            }
            voltage = Double(mv) / 1000
            current = Double(ma) / 1000
            round += 1
            if !fast || round % 3 == 0 {
                let q = slow[slowIndex]
                slowIndex = (slowIndex + 1) % slow.count
                if let f = await send(.query(q))?.frame { applyQuery(q, f) }
            }
            // The DL24P reports a phantom ~250 mA for one reading after a set-current
            // write, even at 0 V with the load off. That isn't data, so it isn't logged.
            if !loadOn, current > 0, Date().timeIntervalSince(lastCurrentWrite) < 0.3 {
                current = 0
                continue
            }
            await sampleTaken()
        }
    }

    private func readSettings() async {
        var readSetpoints = 0
        for q in [Query.load, .setCurrent, .cutoff, .timer, .milliampHours, .milliwattHours, .temperature, .runTime] {
            if let f = await send(.query(q))?.frame {
                applyQuery(q, f)
                if q == .setCurrent || q == .cutoff { readSetpoints += 1 }
            }
        }
        if !hasReadSettings, readSetpoints == 2 {
            // Start from what the DL24P already holds, so connecting changes nothing.
            ccTarget = deviceSetCurrent
            if stops.cutoffV != deviceCutoff { stops.cutoffV = deviceCutoff }
            hasReadSettings = true
        }
    }

    private func applyQuery(_ q: Query, _ f: Frame) {
        switch q {
        case .load:
            let on = f.u24 == 1
            if on != loadOn { loadChanged(on) }
        case .temperature: temperatureC = Double(f.u24 ?? 0)
        case .milliampHours: milliampHours = Double(f.u24 ?? 0)
        case .milliwattHours: milliwattHours = Double(f.u24 ?? 0)
        case .setCurrent: deviceSetCurrent = Double(f.u24 ?? 0) / 100
        case .cutoff: deviceCutoff = Double(f.u24 ?? 0) / 100
        case .timer:
            deviceTimerSeconds = f.hmsSeconds ?? 0
            if loadOn { lastTimerSecondsWhileOn = deviceTimerSeconds }
        case .runTime: if let s = f.hmsSeconds, s > runSeconds || runSeconds < 255 * 3600 { runSeconds = s }
        case .millivolts: voltage = Double(f.u24 ?? 0) / 1000
        case .milliamps: current = Double(f.u24 ?? 0) / 1000
        }
    }

    private func loadChanged(_ on: Bool) {
        loadOn = on
        if on {
            loadBaseMilliampHours = milliampHours
            guardEngine.reset()
            // Also true when it was started from the front panel or the OK button:
            // protection and logging must not depend on who started it.
            commandedLoad = true
            stopRecordingAt = nil
            if autoRecord, recorder == nil { startRecording(name: "Started on DL24P") }
        } else if commandedLoad {
            // It went off without the app asking: DL24 cutoff, timer or front panel.
            commandedLoad = false
            let timerWasArmed = lastTimerSecondsWhileOn > 0 && lastTimerSecondsWhileOn <= 60
            let reason: StopReason
            if deviceCutoff > 0, voltage <= deviceCutoff + 0.05 { reason = .cutoff }
            else if timerWasArmed { reason = .timeLimit }
            else { reason = .deviceTurnedOff }
            if run != nil { applyProgramActions(run!.abort(reason)) } else { finishStop(reason, problem: reason != .cutoff) }
        }
    }

    private func sampleTaken() async {
        let now = Date()
        rateWindow.append(now)
        rateWindow.removeAll { now.timeIntervalSince($0) > 2 }
        sampleRate = Double(rateWindow.count) / 2

        var s = Sample(t: now.timeIntervalSince(liveStart), voltage: voltage, current: current,
                       milliampHours: milliampHours, milliwattHours: milliwattHours,
                       temperatureC: temperatureC, setCurrent: deviceSetCurrent, loadOn: loadOn)
        live.append(s)
        if live.count > 60_000 { live.removeFirst(10_000) }

        if let r = recorder, let start = recordedTimeOffset {
            s.t = now.timeIntervalSince(start)
            r.append(s)
            recordingSeconds = s.t
            recordingSampleCount = r.samples.count
            if let at = stopRecordingAt, now >= at { finishRecording() }
        }
        publishChart(now)

        if loadOn {
            let removed = max(0, milliampHours - loadBaseMilliampHours) / 1000
            if let reason = guardEngine.evaluate(s, capacityAh: removed) {
                if run != nil {
                    applyProgramActions(run!.abort(reason))
                } else {
                    await turnLoadOff(reason: reason)
                }
                return
            }
        }
        if run != nil {
            applyProgramActions(run!.tick(s))
            return
        }
        if loadOn, mode != .cc { await regulate() }
    }

    private func regulate() async {
        let target = mode == .cp ? cpTarget : crTarget
        let next = Regulator.current(mode: mode, target: target, voltage: voltage, previous: regulatedCurrent, limit: currentLimit)
        guard abs(next - regulatedCurrent) >= 0.01, Date().timeIntervalSince(lastRegulation) >= Self.regulationInterval else { return }
        lastRegulation = Date()
        regulatedCurrent = next
        if await !writeCurrent(next) { await turnLoadOff(reason: .deviceRejectedSetting) }
    }

    private func publishChart(_ now: Date) {
        let source = recorder?.samples ?? live
        let interval = source.count > 30_000 ? 1.0 : 0.25
        guard now.timeIntervalSince(lastChartPublish) >= interval else { return }
        lastChartPublish = now
        var view = source[...]
        if let w = chartWindow, let last = source.last {
            let from = last.t - w
            view = source[(source.firstIndex { $0.t >= from } ?? 0)...]
        }
        chartSamples = downsample(Array(view), limit: 500)
    }

    func refreshChart() { lastChartPublish = .distantPast; publishChart(Date()) }

    // MARK: Load

    /// Called by every "turn on" control. Asks first, because the app cannot
    /// read the front panel mode and CV or CR would not honour the setpoint.
    func requestLoadOn() {
        if skipLoadConfirmation { Task { await turnLoadOn() } } else { showLoadConfirmation = true }
    }

    func toggleLoad() {
        if loadOn { Task { await turnLoadOff(reason: .user) } } else { requestLoadOn() }
    }

    func turnLoadOn() async {
        guard isConnected, !loadBusy else { return }
        loadBusy = true
        defer { loadBusy = false }
        banner = nil
        guardEngine = GuardEngine(stops: stops)
        let start: Double
        switch mode {
        case .cc: start = ccTarget
        case .cp, .cr:
            start = Regulator.current(mode: mode, target: mode == .cp ? cpTarget : crTarget, voltage: voltage, previous: 0, limit: currentLimit)
        }
        regulatedCurrent = start
        guard await writeCurrent(start) else {
            banner = StopBanner(title: "The load did not start", detail: "The DL24P did not accept the current setting.", isProblem: true)
            return
        }
        if stops.cutoffEnabled, stops.cutoffV != deviceCutoff, await !writeCutoff(stops.cutoffV) {
            banner = StopBanner(title: "The load did not start", detail: "The DL24P did not accept the cutoff setting.", isProblem: true)
            return
        }
        if autoRecord, recorder == nil { startRecording(name: "\(mode.rawValue) test") }
        stopRecordingAt = nil
        await startLoadVerified()
    }

    private func startLoadVerified() async {
        commandedLoad = true
        guard await send(.setLoad(true), urgent: true) != nil else {
            commandedLoad = false
            banner = StopBanner(title: "The load did not start", detail: "The DL24P did not reply.", isProblem: true)
            return
        }
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(250))
            if let f = await send(.query(.load), urgent: true)?.frame { applyQuery(.load, f) }
            if loadOn { return }
            await send(.setLoad(true), urgent: true)
        }
        // One last look, then make sure a late switch-on cannot go unnoticed.
        try? await Task.sleep(for: .milliseconds(250))
        if let f = await send(.query(.load), urgent: true)?.frame { applyQuery(.load, f) }
        if loadOn { return }
        await send(.setLoad(false), urgent: true)
        commandedLoad = false
        if run == nil { discardRecording() }
        banner = StopBanner(title: "The DL24P stayed off",
                            detail: "It accepted the command but did not start. Check a source is connected and above the cutoff.",
                            isProblem: true)
    }

    func turnLoadOff(reason: StopReason) async {
        commandedLoad = false
        if let r = run, !r.isFinished, reason == .user {
            applyProgramActions(run!.abort(.user))
            return
        }
        // Repeats until the device confirms, because a load left on is the failure that matters.
        for _ in 0..<4 {
            _ = await send(.setLoad(false), urgent: true)
            if let f = await send(.query(.load), urgent: true)?.frame {
                applyQuery(.load, f)
                if !loadOn { break }
            }
        }
        finishStop(reason, problem: reason != .user)
    }

    private func finishStop(_ reason: StopReason, problem: Bool) {
        lastStop = reason
        if reason != .user {
            banner = StopBanner(title: reason.title, detail: reason.detail, isProblem: problem)
            recorder?.mark(reason.title)
        }
        if recorder != nil { stopRecordingAt = Date().addingTimeInterval(3) }
    }

    /// Best effort during quit: the process is going away, so no waiting on a reply.
    func emergencyOffForQuit() {
        guard verified else { return }
        transport?.send(Command.setLoad(false).bytes)
        if loadOn { lastStop = .user }
        finishRecording()
    }

    // MARK: Verified writes

    /// The DL24P silently drops a setting sent too soon after another one, and
    /// it sends no error. So writes run one at a time, spaced apart, and each is
    /// read back and retried. Returns false if the device never took the value.
    private func verifiedWrite(_ command: Command, readback: Query, matches: @escaping (Frame) -> Bool) async -> Bool {
        let previous = writeTail
        let task = Task<Bool, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            for attempt in 1...Self.writeAttempts {
                let wait = Self.writeSpacing - Date().timeIntervalSince(self.lastWrite)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                self.lastWrite = Date()
                await self.send(command, urgent: true)
                try? await Task.sleep(for: .milliseconds(120))
                if let f = await self.send(.query(readback), urgent: true)?.frame {
                    self.applyQuery(readback, f)
                    if matches(f) { return true }
                }
                if attempt < Self.writeAttempts { self.logInfo("Retrying: \(command.label)") }
                guard self.isConnected else { return false }
            }
            self.logInfo("The DL24P did not take: \(command.label)")
            return false
        }
        writeTail = task
        return await task.value
    }

    private func writeCurrent(_ amps: Double) async -> Bool {
        let want = Int((min(max(amps, Command.currentRange.lowerBound), Command.currentRange.upperBound) * 100).rounded())
        lastCurrentWrite = Date()
        defer { lastCurrentWrite = Date() }
        return await verifiedWrite(.setCurrent(amps), readback: .setCurrent) { $0.u24 == want }
    }

    private func writeCutoff(_ volts: Double) async -> Bool {
        let want = Int((min(max(volts, Command.cutoffRange.lowerBound), Command.cutoffRange.upperBound) * 100).rounded())
        return await verifiedWrite(.setCutoff(volts), readback: .cutoff) { $0.u24 == want }
    }

    private func settingFailed(_ what: String) {
        banner = StopBanner(title: "\(what) did not change", detail: "The DL24P did not accept the new value after 3 tries. Its screen shows the value in use.", isProblem: true)
    }

    // MARK: Settings

    func applyCurrent(_ value: Double) {
        ccTarget = min(max(value, 0), Command.currentRange.upperBound)
        guard mode == .cc else { return }
        let target = ccTarget
        Task {
            if await writeCurrent(target) { regulatedCurrent = target } else { settingFailed("Set current") }
        }
    }

    func applyCutoff(_ value: Double) {
        let v = min(max(value, 0), Command.cutoffRange.upperBound)
        stops.cutoffV = v
        deviceCutoff = v   // Shown at once, so a quick second click builds on this one.
        Task { if await !writeCutoff(v) { settingFailed("Cutoff"); stops.cutoffV = deviceCutoff } }
    }

    func applyTimer(minutes: Int) {
        let seconds = min(max(minutes, 0) * 60, Command.maxTimerSeconds)
        deviceTimerSeconds = seconds   // Shown at once, so a quick second click builds on this one.
        Task {
            let ok = await verifiedWrite(.setTimer(seconds: seconds), readback: .timer) { ($0.hmsSeconds ?? -1) / 60 == seconds / 60 }
            if !ok { settingFailed("Timer") }
        }
    }

    func press(_ b: PanelButton) {
        Task {
            await send(.button(b), urgent: true)
            for q in [Query.load, .setCurrent, .cutoff, .timer] {
                if let f = await send(.query(q))?.frame { applyQuery(q, f) }
            }
        }
    }

    /// Saves the current totals first, because a reset cannot be undone.
    func reset(_ r: CounterReset) async -> ReplyStatus? {
        store.appendCounterSnapshot(CounterSnapshot(date: Date(), reset: r.label, milliampHours: milliampHours,
                                                    milliwattHours: milliwattHours, runSeconds: runSeconds))
        let reply = await send(.reset(r), urgent: true)
        for q in [Query.milliampHours, .milliwattHours, .runTime] {
            if let f = await send(.query(q))?.frame { applyQuery(q, f) }
        }
        if case .reply(let s)? = reply?.frame {
            if r == .time || r == .all, case .ok? = s { runSeconds = 0 }
            return s
        }
        return nil
    }

    func sendRaw(_ bytes: [UInt8]) {
        Task { await send(.raw(bytes)) }
    }

    // MARK: Recording

    func startRecording(name: String) {
        guard recorder == nil else { return }
        let r = SessionRecorder(store: store, name: name, transport: transportKind?.rawValue ?? "")
        recorder = r
        recordingName = name
        recordedTimeOffset = Date()
        recordingSeconds = 0
        recordingSampleCount = 0
        stopRecordingAt = nil
        lastStop = nil
        linkDrops = 0
        refreshChart()
    }

    func addMark(_ text: String) { recorder?.mark(text) }

    /// For a load that never started: there is nothing worth keeping.
    private func discardRecording() {
        guard let r = recorder else { return }
        _ = r.finish(stop: nil, result: nil, linkDrops: 0)
        store.delete(r.meta.id)
        recorder = nil
        recordedTimeOffset = nil
        stopRecordingAt = nil
        refreshChart()
    }

    func stopRecordingNow(stop: StopReason?) {
        lastStop = stop ?? lastStop
        finishRecording()
    }

    private func finishRecording(result: ProgramResult? = nil) {
        guard let r = recorder else { return }
        _ = r.finish(stop: lastStop, result: result ?? pendingResult, linkDrops: linkDrops)
        pendingResult = nil
        recorder = nil
        recordedTimeOffset = nil
        stopRecordingAt = nil
        refreshChart()
    }
    private var pendingResult: ProgramResult?

    // MARK: Programs

    func runProgram(_ program: TestProgram) {
        guard isConnected, run == nil else { return }
        banner = nil
        finishRecording()
        var r = ProgramRun(program: program)
        startRecording(name: program.name)
        runBaseAh = milliampHours
        runBaseWh = milliwattHours
        runningProgramID = program.id
        guardEngine = GuardEngine(stops: program.stops)
        let t = recordedElapsed()
        let actions = r.start(at: t)
        run = r
        Task {
            // A leftover DL24 timer would stop the program partway through.
            if deviceTimerSeconds != 0,
               await !verifiedWrite(.setTimer(seconds: 0), readback: .timer, matches: { ($0.hmsSeconds ?? -1) == 0 }) {
                if run != nil { applyProgramActions(run!.abort(.deviceRejectedSetting)) }
                return
            }
            if program.stops.cutoffEnabled, await !writeCutoff(program.stops.cutoffV) {
                if run != nil { applyProgramActions(run!.abort(.deviceRejectedSetting)) }
                return
            }
            applyProgramActions(actions)
        }
    }

    private func recordedElapsed() -> Double { recordedTimeOffset.map { Date().timeIntervalSince($0) } ?? 0 }

    private func applyProgramActions(_ actions: [ProgramAction]) {
        guard !actions.isEmpty else { return }
        Task {
            for a in actions {
                switch a {
                case .setCurrent(let i):
                    if await !writeCurrent(i), run != nil {
                        applyProgramActions(run!.abort(.deviceRejectedSetting))
                        return
                    }
                case .loadOn:
                    if !loadOn { await startLoadVerified() }
                case .loadOff:
                    commandedLoad = false
                    for _ in 0..<4 {
                        _ = await send(.setLoad(false), urgent: true)
                        if let f = await send(.query(.load), urgent: true)?.frame {
                            applyQuery(.load, f)
                            if !loadOn { break }
                        }
                    }
                case .finished(let reason):
                    finishProgram(reason)
                }
            }
        }
    }

    private func finishProgram(_ reason: StopReason) {
        guard let r = run else { return }
        let result = ProgramResult(programName: r.program.name, kind: r.program.kind, steps: r.results,
                                   dcResistanceOhm: ProgramResult.dcResistance(r.results),
                                   capacityAh: max(0, milliampHours - runBaseAh) / 1000,
                                   energyWh: max(0, milliwattHours - runBaseWh) / 1000,
                                   stop: reason, date: Date())
        run = nil
        runningProgramID = nil
        guardEngine = GuardEngine(stops: stops)
        lastStop = reason
        pendingResult = result
        if reason != .finished, reason != .user {
            banner = StopBanner(title: reason.title, detail: reason.detail, isProblem: true)
            recorder?.mark(reason.title)
        }
        stopRecordingAt = Date().addingTimeInterval(2)
    }

    var runProgress: (step: Int, of: Int, elapsed: Double)? {
        guard let r = run else { return nil }
        return (r.stepIndex + 1, r.program.steps.count, r.stepElapsed(at: recordedElapsed()))
    }

    // MARK: Console

    private func logInfo(_ text: String) { addConsole(ConsoleEntry(direction: .info, hex: "", note: text, isStatus: false)) }

    private func logFrame(_ bytes: [UInt8], note: String, direction: ConsoleEntry.Direction = .rx, isStatus: Bool) {
        addConsole(ConsoleEntry(direction: direction, hex: hexString(bytes), note: note, isStatus: isStatus))
    }

    /// Polling never pushes commands out of the console: they have separate logs.
    private func addConsole(_ e: ConsoleEntry) {
        traffic.append(e)
        if traffic.count > 600 { traffic.removeFirst(100) }
        guard !e.isStatus else { return }
        console.append(e)
        if console.count > 600 { console.removeFirst(100) }
    }

    // MARK: Demo

    private func startDemo() {
        let sim = SimulatedDL24()
        demoSim = sim
        seedDemoHistory(sim)
        let t = SimulatedTransport(sim: sim)
        skipLoadConfirmation = false
        attach(t)
    }

    /// Fills the demo with the same scenario as the approved mockup.
    private func seedDemoHistory(_ sim: SimulatedDL24) {
        func runSession(name: String, ampHoursLimit: Double?, rated: Double, current: Double, cutoff: Double, stop: StopReason, ageDays: Double) {
            let s = SimulatedDL24()
            s.ratedAh = rated; s.setCurrent = current; s.cutoff = cutoff; s.loadOn = true
            let r = SessionRecorder(store: store, name: name, transport: "Demo")
            var t = 0.0
            var marked = false
            while s.loadOn, t < 40_000 {
                r.append(Sample(t: t, voltage: s.voltage, current: s.current, milliampHours: s.milliampHours,
                                milliwattHours: s.milliwattHours, temperatureC: s.temperature, setCurrent: current, loadOn: true))
                s.advance(5)
                t += 5
                if !marked, s.milliampHours > rated * 310 { r.mark("Fan at full speed"); marked = true }
            }
            var meta = r.finish(stop: stop, result: nil, linkDrops: 0)
            meta.date = Date().addingTimeInterval(-ageDays * 86400)
            store.save(meta)
        }
        runSession(name: "LiFePO4 pack B", ampHoursLimit: nil, rated: 20, current: 5, cutoff: 10.5, stop: .cutoff, ageDays: 0.1)
        runSession(name: "LiFePO4 pack A", ampHoursLimit: nil, rated: 18, current: 5, cutoff: 10.5, stop: .cutoff, ageDays: 1)

        // A run already in progress on Monitor.
        sim.ccFill(hours: 1.87)
        let base = Date()
        liveStart = base.addingTimeInterval(-1.87 * 3600)
        let replay = SimulatedDL24()
        replay.ratedAh = sim.ratedAh; replay.setCurrent = 5; replay.loadOn = true; replay.cutoff = 10.5
        var t = 0.0
        while t < 1.87 * 3600 {
            live.append(Sample(t: t, voltage: replay.voltage, current: replay.current, milliampHours: replay.milliampHours,
                               milliwattHours: replay.milliwattHours, temperatureC: replay.temperature, setCurrent: 5, loadOn: true))
            replay.advance(10)
            t += 10
        }
        ccTarget = 5
        var demoStops = stops
        demoStops.cutoffV = 10.5
        stops = demoStops
        commandedLoad = true
        hasReadSettings = true
    }
}

private extension SimulatedDL24 {
    func ccFill(hours: Double) {
        setCurrent = 5; cutoff = 10.5; loadOn = true
        var t = 0.0
        while t < hours * 3600 { advance(10); t += 10 }
    }
}
