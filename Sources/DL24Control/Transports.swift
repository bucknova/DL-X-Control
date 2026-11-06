import CoreBluetooth
import DL24Core
import Foundation
import IOKit
import IOKit.serial

enum TransportKind: String, Codable { case usb = "USB", bluetooth = "Bluetooth", demo = "Demo" }

@MainActor
protocol Transport: AnyObject {
    var kind: TransportKind { get }
    var displayName: String { get }
    var onBytes: (([UInt8]) -> Void)? { get set }
    var onClosed: ((String?) -> Void)? { get set }
    func send(_ bytes: [UInt8])
    func close()
}

// MARK: - USB serial

/// Finds CH340 adapters, the DL24P's PC port. Other devices can use the same
/// chip, so the controller only listens until it has heard a valid DL24 frame.
enum SerialDiscovery {
    static let vendor = 0x1A86, product = 0x7523

    static func candidates() -> [String] {
        var iterator: io_iterator_t = 0
        guard let match = IOServiceMatching(kIOSerialBSDServiceValue),
              IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard (property("idVendor") as? Int) == vendor, (property("idProduct") as? Int) == product,
                  let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            out.append(path)
        }
        return out.sorted()
    }
}

@MainActor
final class SerialTransport: Transport {
    let kind = TransportKind.usb
    let path: String
    var displayName: String { path.replacingOccurrences(of: "/dev/cu.", with: "") }
    var onBytes: (([UInt8]) -> Void)?
    var onClosed: ((String?) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init?(path: String) {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        // An exclusive lock, so this can never share a port with another program.
        guard ioctl(fd, UInt(0x2000740D)) == 0 else // TIOCEXCL
         { Darwin.close(fd); fd = -1; return nil }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B9600))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS | HUPCL)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { Darwin.close(fd); fd = -1; return nil }
        tcflush(fd, TCIOFLUSH)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        s.resume()
        source = s
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            onBytes?(Array(buffer[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            shutdown("The USB cable was disconnected.")
        }
    }

    func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        if bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) < 0, errno != EAGAIN {
            shutdown("Writing to USB failed.")
        }
    }

    private func shutdown(_ reason: String?) {
        guard fd >= 0 else { return }
        source?.cancel(); source = nil
        Darwin.close(fd); fd = -1
        onClosed?(reason)
    }

    func close() {
        onClosed = nil
        shutdown(nil)
    }
}

// MARK: - Bluetooth

/// Scans for the FFE0 service, which other devices also use. The MC3000 charger
/// is one of them, so a peripheral is only ever used if its name starts "DL24".
@MainActor
final class BluetoothCentral: NSObject {
    static let service = CBUUID(string: "FFE0")
    static let notify = CBUUID(string: "FFE1")
    static let write = CBUUID(string: "FFE2")
    static func isDL24(_ name: String?) -> Bool { name?.hasPrefix("DL24") == true }

    private var central: CBCentralManager!
    private(set) var state: CBManagerState = .unknown
    var onDiscovered: ((CBPeripheral, Int) -> Void)?
    var onState: ((CBManagerState) -> Void)?
    private var active: BluetoothTransport?
    private var wantsScan = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        wantsScan = true
        if central.state == .poweredOn, !central.isScanning {
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        wantsScan = false
        if central.isScanning { central.stopScan() }
    }

    func connect(_ peripheral: CBPeripheral, name: String) -> BluetoothTransport {
        stopScan()
        let t = BluetoothTransport(peripheral: peripheral, name: name, central: self)
        active = t
        peripheral.delegate = t
        central.connect(peripheral)
        return t
    }

    func cancel(_ t: BluetoothTransport) {
        central.cancelPeripheralConnection(t.peripheral)
        if active === t { active = nil }
    }
}

extension BluetoothCentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        state = c.state
        onState?(c.state)
        if c.state == .poweredOn, wantsScan { startScan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard Self.isDL24(name) else { return }
        onDiscovered?(p, rssi.intValue)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        active?.closedByCentral("Could not connect over Bluetooth.")
        active = nil
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        active?.closedByCentral("The Bluetooth connection dropped.")
        active = nil
    }
}

@MainActor
final class BluetoothTransport: NSObject, Transport {
    let kind = TransportKind.bluetooth
    let peripheral: CBPeripheral
    let displayName: String
    var onBytes: (([UInt8]) -> Void)?
    var onClosed: ((String?) -> Void)?
    var onRSSI: ((Int) -> Void)?
    private weak var central: BluetoothCentral?
    private var writeCharacteristic: CBCharacteristic?
    private var rssiTask: Task<Void, Never>?

    init(peripheral: CBPeripheral, name: String, central: BluetoothCentral) {
        self.peripheral = peripheral
        self.displayName = name
        self.central = central
    }

    func send(_ bytes: [UInt8]) {
        guard let c = writeCharacteristic else { return }
        peripheral.writeValue(Data(bytes), for: c, type: .withoutResponse)
    }

    func close() {
        onClosed = nil
        rssiTask?.cancel()
        central?.cancel(self)
    }

    func closedByCentral(_ reason: String) {
        rssiTask?.cancel()
        onClosed?(reason)
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == BluetoothCentral.service {
            p.discoverCharacteristics([BluetoothCentral.notify, BluetoothCentral.write], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == BluetoothCentral.notify {
                p.setNotifyValue(true, for: c)
                if writeCharacteristic == nil { writeCharacteristic = c }
            }
            if c.uuid == BluetoothCentral.write { writeCharacteristic = c }
        }
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.peripheral.readRSSI()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let v = c.value { onBytes?(Array(v)) }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        onRSSI?(RSSI.intValue)
    }
}

// MARK: - Demo

@MainActor
final class SimulatedTransport: Transport {
    let kind = TransportKind.demo
    let displayName = "Simulated DL24P"
    let sim: SimulatedDL24
    var onBytes: (([UInt8]) -> Void)?
    var onClosed: ((String?) -> Void)?
    private var clock: Task<Void, Never>?
    private var lastCommand = Date.distantPast
    private var lastStatus = Date.distantPast

    init(sim: SimulatedDL24) {
        self.sim = sim
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.sim.advance(0.1)
                if Date().timeIntervalSince(self.lastCommand) > 1, Date().timeIntervalSince(self.lastStatus) > 1 {
                    self.lastStatus = Date()
                    self.onBytes?(self.sim.statusFrame())
                }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.onBytes?(self.sim.statusFrame())
        }
    }

    func send(_ bytes: [UInt8]) {
        lastCommand = Date()
        let reply = sim.receive(bytes)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            self?.onBytes?(reply)
        }
    }

    func close() {
        clock?.cancel()
        onClosed = nil
    }
}
