import DL24Core
import SwiftUI

struct DeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var d = model.device
        VStack(spacing: 8) {
            ScreenHeader(title: "Device", chip: d.isDemo ? "Demo data" : (d.isConnected ? "Values read from your DL24P" : nil)) {
                Picker("Connection", selection: $d.preference) {
                    ForEach(TransportPreference.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
                .disabled(d.isDemo || d.loadOn)
                .help(d.loadOn ? "Turn the load off before changing connection" : "How the app connects to the DL24P")
            }
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    FrontPanelCard()
                    CountersCard()
                }
                .frame(width: 372)
                VStack(spacing: 10) {
                    CapabilitiesCard()
                    ConsoleCard()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct FrontPanelCard: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirmOK = false

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 11) {
            Text("Front panel buttons").fontWeight(.semibold)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                Text(String(format: "%.3f V", d.voltage))
                Text(String(format: "%.3f A", d.current))
                Text(String(format: "Set %.2f A", d.deviceSetCurrent))
                Text(String(format: "Cut %.2f V", d.deviceCutoff))
                Text("Timer \(d.deviceTimerSeconds == 0 ? "off" : formatShortClock(Double(d.deviceTimerSeconds)))")
                Text(String(format: "%.0f °C", d.temperatureC))
            }
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(Color(hex: 0xA5F2C4))
            .padding(.horizontal, 15).padding(.vertical, 13)
            .background(Color(hex: 0x07110D), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    panelButton("Setup") { d.press(.setup) }
                    panelButton("−") { d.press(.minus) }
                    panelButton("+") { d.press(.plus) }
                    panelButton("OK") { if d.voltage > 0.5 { confirmOK = true } else { d.press(.ok) } }
                }
            }
            .disabled(!d.isConnected)
            Text("These press the DL24P's own buttons, so the result depends on what its screen is showing. OK can turn the load on, so the app asks first when a source is connected.")
                .foregroundStyle(Color(hex: 0xD5DBE2))
                .fixedSize(horizontal: false, vertical: true)
            if d.transportKind == .usb {
                Label("USB is not isolated from this Mac. With mains-referenced or high-voltage sources, unplug the cable and use Bluetooth.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .confirmationDialog("Press OK on the DL24P?", isPresented: $confirmOK) {
            Button("Press OK") { d.press(.ok) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: "A source is connected at %.2f V. If the main screen is showing, OK switches the load on or off.", d.voltage))
        }
    }

    private func panelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.glass)
    }
}

struct CountersCard: View {
    @Environment(AppModel.self) private var model
    @LocalState private var pending: CounterReset?
    @LocalState private var message: String?

    var body: some View {
        let d = model.device
        VStack(alignment: .leading, spacing: 10) {
            Text("Stored counters").fontWeight(.semibold)
            row("Capacity", String(format: "%.3f Ah", d.milliampHours / 1000), .capacity)
            row("Energy", String(format: "%.2f Wh", d.milliwattHours / 1000), .energy)
            row("Run time", formatClock(Double(d.runSeconds)), .time)
            Spacer(minLength: 0)
            Button { pending = .all } label: {
                Text("Reset all counters…").fontWeight(.semibold).foregroundStyle(Theme.critical).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(!d.isConnected)
            Text(message ?? "Resets ask for confirmation and save the old values to the log first.")
                .foregroundStyle(message == nil ? Theme.secondary : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .pane(radius: 18)
        .confirmationDialog("Reset \(pending?.label.lowercased() ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let p = pending {
                Button("Reset \(p.label.lowercased())", role: .destructive) {
                    Task {
                        let reply = await d.reset(p)
                        message = reply == .ok ? "\(p.label) reset. The old values are in counter-resets.jsonl." : "The DL24P replied: \(reply?.description ?? "no reply"). Nothing may have changed."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone on the DL24P.")
        }
    }

    private func row(_ a: String, _ b: String, _ reset: CounterReset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(a).foregroundStyle(Color(hex: 0xD5DBE2))
                Text(b).font(.system(size: 18, weight: .semibold).monospacedDigit())
            }
            Spacer()
            Button("Reset…") { pending = reset }.buttonStyle(.glass).disabled(!model.device.isConnected)
        }
        .frame(height: 44)
    }
}

struct CapabilitiesCard: View {
    private enum State { case ok, wait, no }
    private let items: [(String, String, State)] = [
        ("Readings", "Working, to 1 mV and 1 mA", .ok),
        ("Set current", "Working, read back and retried", .ok),
        ("Set cutoff", "Working, read back and retried", .ok),
        ("Timer", "Counts down while on, stops the load at zero", .ok),
        ("Setup, +, −", "Working", .ok),
        ("Load on and off", "Working over USB and Bluetooth", .ok),
        ("OK button", "Working, toggles the load", .ok),
        ("Counter resets", "Working, saved to a file first", .ok),
        ("Backlight, price", "Rejected by this firmware", .no),
        ("Front panel CV, CR, CP", "Set on the panel only, app cannot read", .no),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What works over USB and Bluetooth").fontWeight(.semibold)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], spacing: 0) {
                ForEach(items, id: \.0) { item in
                    HStack(spacing: 9) {
                        Image(systemName: symbol(item.2)).foregroundStyle(color(item.2)).frame(width: 16)
                        Text(item.0).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(item.1).font(.caption).foregroundStyle(Color(hex: 0xD5DBE2)).multilineTextAlignment(.trailing).lineLimit(2)
                    }
                    .frame(minHeight: 38)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .pane(radius: 18)
    }

    private func symbol(_ s: State) -> String { s == .ok ? "checkmark" : s == .wait ? "clock" : "xmark" }
    private func color(_ s: State) -> Color { s == .ok ? Theme.good : s == .wait ? Theme.warn : Theme.critical }
}

struct ConsoleCard: View {
    @Environment(AppModel.self) private var model
    @LocalState private var raw = ""
    @LocalState private var error: String?

    var body: some View {
        @Bindable var d = model.device
        let entries = (d.showStatusFrames ? d.traffic : d.console).suffix(300)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Protocol console").fontWeight(.semibold)
                Text(d.showStatusFrames ? "All traffic" : "Commands only").foregroundStyle(Theme.secondary)
                Spacer()
                Toggle("Show polling and status frames", isOn: $d.showStatusFrames).controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(e.direction.rawValue).fontWeight(.semibold).foregroundStyle(color(e)).frame(width: 24, alignment: .leading)
                                if !e.hex.isEmpty {
                                    Text(e.hex).textSelection(.enabled).frame(width: 300, alignment: .leading)
                                }
                                Text(e.note).font(.callout).foregroundStyle(Theme.secondary)
                            }
                            .id(e.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.last?.id) { _, id in
                    if let id, entries.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Text("Send raw").foregroundStyle(Color(hex: 0xD5DBE2))
                TextField("B1 B2 17 00 00 B6", text: $raw)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(send)
                if let error { Text(error).font(.caption).foregroundStyle(Theme.critical) }
                Button("Send", action: send).buttonStyle(.glass).disabled(!d.isConnected || raw.isEmpty)
            }
            .padding(.leading, 15).padding(.trailing, 6).frame(height: 42)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxHeight: .infinity)
        .pane(radius: 18)
    }

    private func color(_ e: ConsoleEntry) -> Color {
        switch e.direction {
        case .tx: Color(hex: 0x8FC2FF)
        case .rx: e.note == "Unsupported" || e.note == "Failed" ? Theme.critical : Theme.good
        case .info: Theme.secondary
        }
    }

    private func send() {
        guard let bytes = parseHex(raw) else { error = "Enter hex bytes, like B1 B2 17 00 00 B6"; return }
        error = nil
        model.device.sendRaw(bytes)
        raw = ""
    }
}
