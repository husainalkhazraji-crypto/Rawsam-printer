import CoreBluetooth
import SwiftUI

struct FoundDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
    var id: UUID { peripheral.identifier }
}

final class PrinterManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var devices: [FoundDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var bluetoothOff = false
    @Published var writeTargets: [CBCharacteristic] = []
    @Published var selectedTarget: CBCharacteristic?
    @Published private(set) var progress: Double?
    @Published private(set) var lastMessage: String?
    @Published private(set) var log: [String] = []

    private var central: CBCentralManager!
    private var current: CBPeripheral?
    private var outgoing = Data()
    private var offset = 0
    private var awaitingResponse = false
    private var wantsScan = false

    private let lastIDKey = "lastPrinterID"
    private let lastNameKey = "lastPrinterName"

    /// قنوات الكتابة الشائعة بطابعات البلوتوث الصينية، حسب الأولوية.
    private let preferred = ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "AE01",
                             "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "FFF2", "FFE1", "2AF1"]

    var isReady: Bool { selectedTarget != nil && current != nil }
    var isPrinting: Bool { progress != nil }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func looksLikePrinter(_ device: FoundDevice) -> Bool {
        let n = device.name.uppercased()
        if n == UserDefaults.standard.string(forKey: lastNameKey)?.uppercased() { return true }
        return ["MHT", "P19", "HERCULES", "PRINTER", "TATTOO", "STENCIL", "GT-", "IMP-", "PRT", "PHOMEMO", "M08", "ITARI", "ATS", "A4"].contains { n.contains($0) }
    }

    private func note(_ text: String) {
        log.append(text)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    // MARK: - البحث والاتصال

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil)
    }

    func stopScan() {
        wantsScan = false
        if central.state == .poweredOn { central.stopScan() }
    }

    func connect(_ device: FoundDevice) {
        stopScan()
        disconnect(forget: false)
        UserDefaults.standard.set(device.id.uuidString, forKey: lastIDKey)
        UserDefaults.standard.set(device.name, forKey: lastNameKey)
        open(device.peripheral)
    }

    private func open(_ peripheral: CBPeripheral) {
        current = peripheral
        peripheral.delegate = self
        isConnecting = true
        note("connect \(peripheral.name ?? "?")")
        central.connect(peripheral)
    }

    /// يرجع يتصل بآخر طابعة تلقائياً من تتشغل.
    private func reconnectLast() {
        guard current == nil, central.state == .poweredOn,
              let saved = UserDefaults.standard.string(forKey: lastIDKey),
              let uuid = UUID(uuidString: saved),
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
        open(peripheral)
    }

    func disconnect(forget: Bool) {
        if forget {
            UserDefaults.standard.removeObject(forKey: lastIDKey)
        }
        if let p = current { central.cancelPeripheralConnection(p) }
        reset()
    }

    private func reset() {
        current = nil
        connectedName = nil
        isConnecting = false
        writeTargets = []
        selectedTarget = nil
        progress = nil
        outgoing = Data()
        offset = 0
        awaitingResponse = false
    }

    // MARK: - الإرسال

    func send(_ data: Data) {
        guard current != nil, selectedTarget != nil, !isPrinting else { return }
        outgoing = data
        offset = 0
        awaitingResponse = false
        progress = 0
        lastMessage = nil
        note("send \(data.count) bytes")
        pump()
    }

    func cancelPrint() {
        guard isPrinting else { return }
        // قطع الاتصال أضمن طريقة لإيقاف مهمة بنصها، وبعدها نرجع نتصل.
        disconnect(forget: false)
        lastMessage = "انلغت الطباعة"
        reconnectLast()
    }

    private func pump() {
        guard isPrinting, let p = current, let c = selectedTarget else { return }
        let fast = c.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = fast ? .withoutResponse : .withResponse
        let size = max(20, min(p.maximumWriteValueLength(for: type), 512))
        while offset < outgoing.count {
            if fast && !p.canSendWriteWithoutResponse { return }
            if !fast && awaitingResponse { return }
            let end = min(offset + size, outgoing.count)
            awaitingResponse = !fast
            p.writeValue(outgoing.subdata(in: offset..<end), for: c, type: type)
            offset = end
            progress = Double(offset) / Double(outgoing.count)
        }
        if !awaitingResponse {
            progress = nil
            lastMessage = "خلص الإرسال للطابعة"
            note("send complete")
        }
    }

    func report() -> String {
        var lines = ["Rawsam printer diagnostic", "device: \(connectedName ?? "-")"]
        for service in current?.services ?? [] {
            lines.append("service \(service.uuid.uuidString)")
            for c in service.characteristics ?? [] {
                lines.append("  char \(c.uuid.uuidString) props=\(c.properties.rawValue)")
            }
        }
        lines.append("write target: \(selectedTarget?.uuid.uuidString ?? "-")")
        return (lines + log).joined(separator: "\n")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOff = central.state == .poweredOff || central.state == .unauthorized
        if central.state == .poweredOn {
            if wantsScan { scan() }
            reconnectLast()
        } else {
            reset()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = advertised ?? peripheral.name, !name.isEmpty else { return }
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(FoundDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue))
            devices.sort { a, b in
                let pa = looksLikePrinter(a), pb = looksLikePrinter(b)
                return pa != pb ? pa : a.rssi > b.rssi
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == current else { return }
        connectedName = peripheral.name ?? UserDefaults.standard.string(forKey: lastNameKey) ?? "طابعة"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == current else { return }
        note("connect failed: \(error?.localizedDescription ?? "?")")
        reset()
        lastMessage = "فشل الاتصال بالطابعة"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == current else { return }
        note("disconnected: \(error?.localizedDescription ?? "-")")
        reset()
        // انفصلت وحدها (انطفت أو بعدت): ننتظرها ترجع.
        reconnectLast()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == current else { return }
        let system = ["1800", "1801", "180A", "180F"]
        for c in service.characteristics ?? [] {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            let writable = c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
            if writable && !system.contains(service.uuid.uuidString) && !writeTargets.contains(c) {
                writeTargets.append(c)
            }
        }
        guard !isPrinting else { return }
        func rank(_ c: CBCharacteristic) -> Int { preferred.firstIndex(of: c.uuid.uuidString) ?? preferred.count }
        selectedTarget = writeTargets.min { rank($0) < rank($1) }
        if selectedTarget != nil { isConnecting = false }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            note("write error: \(error.localizedDescription)")
            progress = nil
            awaitingResponse = false
            lastMessage = "خطأ بالإرسال للطابعة"
            return
        }
        awaitingResponse = false
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let hex = value.map { String(format: "%02X", $0) }.joined(separator: " ")
        let text = String(decoding: value.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
        note("rx \(characteristic.uuid.uuidString): \(hex)  \(text)")
    }
}
