import CoreBluetooth
import SwiftUI

struct FoundDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
    var id: UUID { peripheral.identifier }
    var looksLikePrinter: Bool {
        let n = name.uppercased()
        return ["MHT", "P19", "HERCULES", "PRINTER", "TATTOO", "GT-", "IMP-"].contains { n.contains($0) }
    }
}

final class PrinterManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [FoundDevice] = []
    @Published var status = "غير متصل"
    @Published var connectedName: String?
    @Published var writeTargets: [CBCharacteristic] = []
    @Published var selectedTarget: CBCharacteristic?
    @Published var progress: Double?
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var current: CBPeripheral?
    private var outgoing = Data()
    private var offset = 0
    private var awaitingResponse = false
    private var wantsScan = false

    /// قنوات الكتابة الشائعة بطابعات البلوتوث الصينية، حسب الأولوية.
    private let preferred = ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "AE01",
                             "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "FFF2", "FFE1", "2AF1"]

    var isReady: Bool { selectedTarget != nil }
    var isPrinting: Bool { progress != nil }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func note(_ text: String) {
        log.append(text)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil)
        status = "أدور على الأجهزة…"
    }

    func stopScan() {
        wantsScan = false
        if central.state == .poweredOn { central.stopScan() }
        if connectedName == nil { status = "غير متصل" }
    }

    func connect(_ device: FoundDevice) {
        central.stopScan()
        wantsScan = false
        disconnect()
        current = device.peripheral
        current?.delegate = self
        status = "أتصل بـ \(device.name)…"
        note("connect \(device.name)")
        central.connect(device.peripheral)
    }

    func disconnect() {
        if let p = current { central.cancelPeripheralConnection(p) }
        reset()
    }

    private func reset() {
        current = nil
        connectedName = nil
        writeTargets = []
        selectedTarget = nil
        progress = nil
        outgoing = Data()
        offset = 0
        awaitingResponse = false
        status = "غير متصل"
    }

    func send(_ data: Data) {
        guard current != nil, selectedTarget != nil, !isPrinting else { return }
        outgoing = data
        offset = 0
        awaitingResponse = false
        progress = 0
        status = "أرسل للطابعة…"
        note("send \(data.count) bytes")
        pump()
    }

    func cancelPrint() {
        guard isPrinting else { return }
        // قطع الاتصال أضمن طريقة لإيقاف مهمة بنصها.
        disconnect()
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
            status = "خلص الإرسال"
            note("send complete")
        }
    }

    func report() -> String {
        var lines = ["Washm diagnostic", "device: \(connectedName ?? "-")"]
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
        switch central.state {
        case .poweredOn: if wantsScan { scan() }
        case .poweredOff: reset(); status = "شغّل البلوتوث"
        case .unauthorized: reset(); status = "اسمح للتطبيق بالبلوتوث من الإعدادات"
        default: break
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
            devices.sort { ($0.looksLikePrinter ? 1 : 0, $0.rssi) > ($1.looksLikePrinter ? 1 : 0, $1.rssi) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == current else { return }
        connectedName = peripheral.name ?? "طابعة"
        status = "متصل، أفحص القنوات…"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == current else { return }
        note("connect failed: \(error?.localizedDescription ?? "?")")
        reset()
        status = "فشل الاتصال"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == current else { return }
        note("disconnected: \(error?.localizedDescription ?? "-")")
        reset()
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
        // لا نغير القناة أثناء الطباعة.
        guard !isPrinting else { return }
        func rank(_ c: CBCharacteristic) -> Int { preferred.firstIndex(of: c.uuid.uuidString) ?? preferred.count }
        selectedTarget = writeTargets.min { rank($0) < rank($1) }
        status = selectedTarget == nil ? "متصل، بس ما لكيت قناة طباعة" : "جاهزة للطباعة"
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            note("write error: \(error.localizedDescription)")
            progress = nil
            awaitingResponse = false
            status = "خطأ بالإرسال"
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
