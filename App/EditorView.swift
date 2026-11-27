import SwiftUI

struct EditorView: View {
    let design: Design
    @EnvironmentObject private var printer: PrinterManager
    @AppStorage("printMode") private var mode: PrintMode = .mhtLegacy
    @AppStorage("density") private var density: Density = .low
    @State private var source: UIImage?
    @State private var settings = EditSettings()
    @State private var bitmap: Bitmap?
    @State private var preview: UIImage?
    @State private var working = true

    private struct RenderKey: Equatable {
        let settings: EditSettings
        let width: Int
        let loaded: Bool
    }

    var body: some View {
        Form {
            Section("معاينة الطباعة (عرض الورقة 21 سم)") {
                ZStack {
                    Color.white
                    if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                    if working { ProgressView().tint(.black) }
                }
                .frame(height: 320)
                // المعاينة صورة، فلا تنقلب مع اتجاه الواجهة.
                .environment(\.layoutDirection, .leftToRight)
                if let bitmap {
                    Text("طول الطباعة: \(Double(bitmap.height) / 80, specifier: "%.1f") سم")
                        .foregroundStyle(.secondary)
                }
            }
            Section("التعديل") {
                slider("العرض: \(Int(settings.widthMM)) ملم", value: $settings.widthMM, range: 20...208, step: 1)
                slider("الغمقان", value: $settings.threshold, range: 0.1...0.9, step: 0.01)
                HStack {
                    Button("تدوير", systemImage: "rotate.right") { settings.rotation = (settings.rotation + 90) % 360 }
                    Spacer()
                    Button("الأصلي", systemImage: "arrow.uturn.backward") { settings = EditSettings() }
                }
                .buttonStyle(.bordered)
                Toggle("قلب كالمرآة", isOn: $settings.mirrored)
                Toggle("استخراج الخطوط من صورة", isOn: $settings.outline)
                Toggle("تظليل (للتدرجات)", isOn: $settings.dither)
                Toggle("عكس الألوان", isOn: $settings.inverted)
            }
            Section("الطباعة") {
                Picker("كثافة الحرارة", selection: $density) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                .disabled(mode == .escpos)
                if let progress = printer.progress {
                    ProgressView(value: progress)
                    Button("إيقاف", role: .destructive) { printer.cancelPrint() }
                } else {
                    Button("اطبع", systemImage: "printer.fill") {
                        if let bitmap { printer.send(PrinterProtocol.job(bitmap, mode: mode, density: density)) }
                    }
                    .disabled(!printer.isReady || bitmap == nil || working)
                }
                Text(printer.status).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(design.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { source = UIImage(contentsOfFile: design.url.path); if source == nil { working = false } }
        .task(id: RenderKey(settings: settings, width: mode.widthDots, loaded: source != nil)) {
            guard let source else { return }
            working = true
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let current = settings
            let width = mode.widthDots
            let result = await Task.detached(priority: .userInitiated) { () -> (Bitmap, UIImage?)? in
                guard let b = ImageProcessor.render(source, settings: current, headWidth: width) else { return nil }
                return (b, ImageProcessor.preview(b))
            }.value
            if Task.isCancelled { return }
            bitmap = result?.0
            preview = result?.1
            working = false
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: value, in: range, step: step)
        }
    }
}
