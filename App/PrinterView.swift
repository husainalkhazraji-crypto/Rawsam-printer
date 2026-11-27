import SwiftUI
import CoreBluetooth

struct PrinterView: View {
    @EnvironmentObject private var printer: PrinterManager
    @AppStorage("printMode") private var mode: PrintMode = .mhtLegacy
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("الحالة") {
                    Text(printer.status)
                    if let name = printer.connectedName {
                        Text(name).bold()
                        Button("قطع الاتصال", role: .destructive) { printer.disconnect() }
                    }
                }
                Section {
                    Button("ابحث عن الطابعة", systemImage: "antenna.radiowaves.left.and.right") { printer.scan() }
                        .disabled(printer.isPrinting)
                    ForEach(printer.devices) { device in
                        Button { printer.connect(device) } label: {
                            HStack {
                                Image(systemName: device.looksLikePrinter ? "printer.fill" : "dot.radiowaves.right")
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi)").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(printer.isPrinting)
                    }
                } header: { Text("الأجهزة") } footer: {
                    Text("شغّل الطابعة، واقفل أي تطبيق طباعة ثاني متصل بيها.")
                }
                Section {
                    Picker("طريقة الإرسال", selection: $mode) {
                        ForEach(PrintMode.allCases) { Text($0.title).tag($0) }
                    }
                    Button("اطبع مستطيل الاختبار (4×2 سم)") {
                        let test = PrinterProtocol.calibration(width: mode.widthDots)
                        printer.send(PrinterProtocol.job(test, mode: mode, density: .low))
                    }
                    .disabled(!printer.isReady || printer.isPrinting)
                } header: { Text("الاختبار") } footer: {
                    Text("جرّب الطرق بالترتيب. الصحيحة تطلع مستطيل قياسه 4×2 سم.")
                }
                if printer.connectedName != nil {
                    Section("للمطور") {
                        Picker("قناة الكتابة", selection: $printer.selectedTarget) {
                            ForEach(printer.writeTargets, id: \.self) {
                                Text($0.uuid.uuidString).tag(Optional($0))
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .disabled(printer.isPrinting)
                        Button("اسأل الطابعة عن موديلها") { printer.send(Data(PrinterProtocol.queryModel)) }
                            .disabled(!printer.isReady || printer.isPrinting)
                        Button("اسأل عن إصدار النظام") { printer.send(Data(PrinterProtocol.queryFirmware)) }
                            .disabled(!printer.isReady || printer.isPrinting)
                        Button(copied ? "انتسخ ✓" : "انسخ تقرير الفحص") {
                            UIPasteboard.general.string = printer.report()
                            copied = true
                        }
                    }
                }
            }
            .navigationTitle("الطابعة")
            .onDisappear { printer.stopScan() }
        }
    }
}
