import AppKit
import DLXCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case monitor = "Monitor", logger = "Logger", tests = "Tests", device = "Device"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .monitor: "waveform.path.ecg"
        case .logger: "list.bullet.rectangle"
        case .tests: "chart.bar.xaxis.ascending"
        case .device: "slider.horizontal.below.rectangle"
        }
    }
}

@MainActor @Observable
final class AppModel {
    let store: SessionStore
    let device: DeviceController
    var screen: Screen = .monitor
    var selectedSession: UUID?
    var selectedProgram: UUID?
    var newestSessionSeen: UUID?

    init() {
        let args = ProcessInfo.processInfo.arguments
        let demo = args.contains("--demo")
        let store = SessionStore(demo: demo)
        self.store = store
        device = DeviceController(store: store, demo: demo)
        selectedSession = store.sessions.first?.id
        newestSessionSeen = selectedSession
        selectedProgram = store.programs.first?.id
        if let i = args.firstIndex(of: "--screen"), i + 1 < args.count, let s = Screen(rawValue: args[i + 1]) { screen = s }
        // Diagnostic: writes the newest session in every export format to a folder.
        if let i = args.firstIndex(of: "--export-newest"), i + 1 < args.count, let m = store.sessions.first {
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.copyItem(at: store.samplesURL(m.id), to: dir.appendingPathComponent("export.csv"))
            try? store.exportJSON(m)?.write(to: dir.appendingPathComponent("export.json"))
            renderReportPDF(meta: m, samples: store.samples(for: m.id), to: dir.appendingPathComponent("export.pdf"))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ n: Notification) { onQuit?() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

@main
struct DLXControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @LocalState private var model = AppModel()

    var body: some Scene {
        Window("DL-X Control", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1240, minHeight: 800)
                .onAppear {
                    let device = model.device
                    delegate.onQuit = { MainActor.assumeIsolated {
                        device.emergencyOffForQuit()
                        // Give the final command a moment to leave before the process ends.
                        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    } }
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandMenu("Load") {
                Button(model.device.loadOn ? "Turn Load Off" : "Turn Load On…") { model.device.toggleLoad() }
                    .disabled(!model.device.isConnected)
                Button("Turn Load Off Now") { Task { await model.device.turnLoadOff(reason: .user) } }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button(model.device.recorder == nil ? "Start Recording" : "Stop Recording") {
                    if model.device.recorder == nil { model.device.startRecording(name: "Recording") }
                    else { model.device.stopRecordingNow(stop: nil) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Add Mark") { model.device.addMark("Mark") }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.device.recorder == nil)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(Screen.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.rawValue) { model.screen = s }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MenuBarPanel().environment(model).preferredColorScheme(.dark)
        } label: {
            if model.device.loadOn {
                Text(String(format: "%.2f A  %.1f W", model.device.current, model.device.voltage * model.device.current))
                    .monospacedDigit()
            } else {
                Image(systemName: "bolt.horizontal")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DL-X Control").font(.headline)
                Spacer()
                LinkLabel(device: d).font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Voltage").foregroundStyle(.secondary); Text(String(format: "%.3f V", d.voltage)) }
                GridRow { Text("Current").foregroundStyle(.secondary); Text(String(format: "%.3f A", d.current)) }
                GridRow { Text("Power").foregroundStyle(.secondary); Text(String(format: "%.2f W", d.voltage * d.current)) }
                GridRow { Text("Temperature").foregroundStyle(.secondary); Text(String(format: "%.0f °C", d.temperatureC)) }
            }
            .monospacedDigit()
            Button {
                d.toggleLoad()
                if !d.loadOn { openWindow(id: "main") }
            } label: {
                Text(d.loadOn ? "Turn load off" : "Turn load on…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(d.loadOn ? Theme.loadOn : .accentColor)
            .disabled(!d.isConnected)
            HStack {
                Button("Open window") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var device = model.device
        HStack(spacing: 10) {
            SidebarView()
                .frame(width: 224)
                .frame(maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
            VStack(spacing: 8) {
                BannerStrip()
                switch model.screen {
                case .monitor: MonitorView()
                case .logger: LoggerView()
                case .tests: TestsView()
                case .device: DeviceView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(6)
        .padding(.trailing, 4)
        .ignoresSafeArea(.container, edges: .top)
        .containerBackground(for: .window) { Theme.wallpaper }
        .background(TrafficLightPlacer())
        .sheet(isPresented: $device.showLoadConfirmation) { LoadConfirmSheet() }
    }
}

/// The floating header from the mockup: a title on the left and actions on
/// Liquid Glass capsules on the right.
struct ScreenHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    var chip: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            if let chip {
                Text(chip).font(.caption).foregroundStyle(Color(hex: 0xD5DBE2))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 9))
            }
            if let subtitle {
                Text(subtitle).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 12)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) { actions() }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .frame(height: 44)
        .padding(.horizontal, 4)
    }
}

struct BannerStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let b = model.device.banner {
            HStack(spacing: 10) {
                Image(systemName: b.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(b.isProblem ? Theme.critical : Theme.good)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.title).fontWeight(.semibold)
                    if !b.detail.isEmpty { Text(b.detail).foregroundStyle(Theme.secondary) }
                }
                Spacer()
                Button("Dismiss") { model.device.banner = nil }.buttonStyle(.glass)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}

struct LoadConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @LocalState private var dontAsk = false

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 14) {
            Label("Turn the load on?", systemImage: "bolt.fill").font(.title2.bold())
            Text("Set the DL24P's front panel to CC first. The app cannot read the panel mode, and in CV or CR the load ignores this app's current setting.")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow { Text("Input now").foregroundStyle(Theme.secondary); Text(String(format: "%.3f V", d.voltage)) }
                GridRow { Text(d.mode.setpointName).foregroundStyle(Theme.secondary); Text(targetText(d)) }
                if d.mode != .cc { GridRow { Text("Current limit").foregroundStyle(Theme.secondary); Text(String(format: "%.2f A", d.currentLimit)) } }
                GridRow { Text("Cutoff").foregroundStyle(Theme.secondary); Text(String(format: "%.2f V", d.stops.cutoffV)) }
                if d.deviceTimerSeconds > 0 {
                    GridRow {
                        Text("DL24P timer").foregroundStyle(Theme.warn)
                        Text("Stops the load after \(d.deviceTimerSeconds / 60) min").foregroundStyle(Theme.warn)
                    }
                }
            }
            .monospacedDigit()
            Text("The app also turns the load off if current goes above the setting.").foregroundStyle(Theme.secondary)
            Toggle("Don't ask again until I quit", isOn: $dontAsk)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Panel is in CC, turn on") {
                    d.skipLoadConfirmation = dontAsk
                    dismiss()
                    Task { await d.turnLoadOn() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(Theme.loadOn)
                .foregroundStyle(.black)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func targetText(_ d: DeviceController) -> String {
        switch d.mode {
        case .cc: String(format: "%.2f A", d.ccTarget)
        case .cp: String(format: "%.1f W", d.cpTarget)
        case .cr: String(format: "%.2f Ω", d.crTarget)
        }
    }
}

struct LinkLabel: View {
    let device: DeviceController
    var body: some View {
        switch device.link {
        case .connected:
            Label("Connected", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(Theme.good)
        case .searching:
            Label("Searching", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(Theme.warn)
        case .verifying:
            Label("Checking", systemImage: "ellipsis").foregroundStyle(Theme.warn)
        case .bluetoothUnavailable:
            Label("Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.critical)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // Clears the window's traffic lights, which sit on the panel.
            Color.clear.frame(height: 44)
            VStack(spacing: 4) {
                ForEach(Screen.allCases) { s in
                    Button { model.screen = s } label: {
                        Label(s.rawValue, systemImage: s.symbol)
                            .fontWeight(model.screen == s ? .semibold : .regular)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(model.screen == s ? Color.white.opacity(0.17) : .clear, in: .rect(cornerRadius: 11))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.screen == s ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            Group {
                switch model.screen {
                case .logger: SessionList()
                case .tests: ProgramList()
                default: Spacer()
                }
            }
            .frame(maxHeight: .infinity)

            ConnectionCard().padding(10)
        }
    }
}

struct ConnectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 4) {
            LinkLabel(device: d).fontWeight(.semibold)
            switch d.link {
            case .connected:
                Text(d.deviceName).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(connectionDetail(d)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
            case .searching:
                Text("Looking for a DL24P on USB and Bluetooth.").foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            case .verifying(let n):
                Text("Listening to \(n).").foregroundStyle(Theme.secondary).lineLimit(2)
            case .bluetoothUnavailable(let why):
                Text(why).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.paneFill, in: .rect(cornerRadius: 13))
    }

    private func connectionDetail(_ d: DeviceController) -> String {
        var parts = [d.transportKind?.rawValue ?? ""]
        if let r = d.rssi { parts.append("\(r) dBm") }
        if d.sampleRate > 0 { parts.append(String(format: "%.0f Hz", d.sampleRate)) }
        return parts.joined(separator: ", ")
    }
}
