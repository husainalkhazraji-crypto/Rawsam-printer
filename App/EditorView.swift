import SwiftUI
import PhotosUI

enum Tool: String, CaseIterable, Identifiable {
    case edit, crop, copy, text, add, heat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .edit: return "تعديل"
        case .crop: return "قص"
        case .copy: return "نسخ"
        case .text: return "نص"
        case .add: return "إضافة"
        case .heat: return "الحرارة"
        }
    }
    var icon: String {
        switch self {
        case .edit: return "wand.and.stars"
        case .crop: return "crop"
        case .copy: return "plus.square.on.square"
        case .text: return "textformat"
        case .add: return "photo.badge.plus"
        case .heat: return "flame"
        }
    }
    var needsSelection: Bool { [.edit, .crop, .copy].contains(self) }
}

let darkHeatWarning = "يرجى استخدام هذا الخيار فقط في الرسمات ذات الخطوط الدقيقة"

struct EditorView: View {
    let source: DesignSource
    @EnvironmentObject private var printer: PrinterManager
    @StateObject private var model = EditorModel()
    @AppStorage("printMode") private var mode: PrintMode = .mhtLegacy
    @AppStorage("density") private var density: Density = .normal
    @State private var panel: Tool?
    @State private var loading = true
    @State private var rendering = false
    @State private var showPrinters = false
    @State private var cropping = false
    @State private var textSheet = false
    @State private var heatWarning = false
    @State private var addPick: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            CanvasView(model: model)
                .padding(.horizontal, 6)
                .overlay { if loading { ProgressView().controlSize(.large) } }
            if let panel { panelView(panel) }
            toolbar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("تعديل")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: printNow) {
                    if rendering { ProgressView() } else {
                        Label("اطبع", systemImage: "printer.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.brand))
                    }
                }
                .disabled(model.layers.isEmpty || rendering || printer.isPrinting)
            }
        }
        .overlay { if printer.progress != nil { printingCard } }
        .sheet(isPresented: $showPrinters) { PrinterPicker() }
        .sheet(isPresented: $cropping) {
            if let layer = model.selected {
                CropView(image: layer.source, rect: layer.crop) { rect in model.update { $0.crop = rect } }
            }
        }
        .sheet(isPresented: $textSheet) {
            TextSheet(initial: model.selected?.text ?? "") { text in
                if model.selected?.text != nil { model.updateText(text) } else { model.addText(text) }
            }
            .presentationDetents([.height(230)])
        }
        .alert("تنبيه", isPresented: $heatWarning) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(darkHeatWarning)
        }
        .onChange(of: density) { _, new in if new == .thick { heatWarning = true } }
        .onChange(of: model.selectedID) { _, _ in
            if panel == .edit && (model.selected == nil || model.selected?.text != nil) { panel = nil }
        }
        .onChange(of: addPick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    model.add(image: image)
                }
                addPick = nil
            }
        }
        .task {
            guard model.layers.isEmpty else { return }
            if let image = await source.load() { model.add(image: image) }
            loading = false
        }
        .task(id: model.layers.map(\.key)) {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            await model.processPending()
        }
    }

    // MARK: - الشريط العلوي

    private var infoBar: some View {
        HStack(spacing: 14) {
            if let layer = model.selected {
                let b = model.bounds(layer)
                value("x", b.minX)
                value("y", b.minY)
                value("w", layer.widthMM)
                value("h", layer.heightMM)
                Text("r:\(Int(layer.rotation.rounded()))°")
            } else {
                Text("A4 · 210 × 297 mm")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func value(_ name: String, _ v: CGFloat) -> some View {
        Text("\(name):\(Double(v), specifier: "%.1f")")
    }

    // MARK: - الأدوات

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { tool in
                Group {
                    if tool == .add {
                        PhotosPicker(selection: $addPick, matching: .images) { toolLabel(tool) }
                    } else {
                        Button { tap(tool) } label: { toolLabel(tool) }
                            .disabled(!enabled(tool))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.white)
    }

    private func enabled(_ tool: Tool) -> Bool {
        guard tool.needsSelection else { return true }
        guard let layer = model.selected else { return false }
        return tool != .edit || layer.text == nil
    }

    private func toolLabel(_ tool: Tool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: tool.icon).font(.system(size: 20))
            Text(tool.title).font(.caption2)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(panel == tool ? Color.brand : (enabled(tool) ? Color.primary : Color.secondary.opacity(0.5)))
        .background(RoundedRectangle(cornerRadius: 10).fill(panel == tool ? Color.brand.opacity(0.1) : .clear))
        .contentShape(Rectangle())
    }

    private func tap(_ tool: Tool) {
        switch tool {
        case .edit: withAnimation(.snappy) { panel = panel == .edit ? nil : .edit }
        case .heat: withAnimation(.snappy) { panel = panel == .heat ? nil : .heat }
        case .crop: cropping = true
        case .copy: model.duplicate()
        case .text: textSheet = true
        case .add: break
        }
    }

    @ViewBuilder
    private func panelView(_ tool: Tool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tool {
            case .edit: editPanel
            case .heat: heatPanel
            default: EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }

    private var styleBinding: Binding<ImageStyle> {
        Binding(get: { model.selected?.style ?? ImageStyle() }, set: { s in model.update { $0.style = s } })
    }

    /// الصورة تبقى على حالها لحد ما المستخدم يختار رسم عادي أو AI.
    private var modeBinding: Binding<ImageMode> {
        Binding(get: { model.selected?.style.mode ?? .original },
                set: { mode in
                    model.aiError = nil
                    model.update {
                        switch mode {
                        case .original: $0.style.mode = .original
                        case .drawing: $0.style = .pencil
                        case .ai: $0.style = .aiStencil
                        }
                    }
                })
    }

    @ViewBuilder
    private var editPanel: some View {
        Picker("", selection: modeBinding) {
            Text("الأصلية").tag(ImageMode.original)
            Text("رسم عادي").tag(ImageMode.drawing)
            if LineArtAI.available { Text("رسم AI").tag(ImageMode.ai) }
        }
        .pickerStyle(.segmented)
        if model.aiWorking {
            HStack(spacing: 8) {
                ProgressView()
                Text("الـ AI يرسم…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.selected?.style.mode == .ai && !model.aiWorking && model.aiError == nil {
            Label("رسمها الـ AI", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Color.ok)
        }
        if let error = model.aiError {
            Text("ما گدر الـ AI يرسم: \(error)").font(.caption).foregroundStyle(Color.brand)
        }
        if let mode = model.selected?.style.mode, mode != .original {
            let locked = mode == .ai && !styleBinding.wrappedValue.custom
            if mode == .ai {
                Toggle("تطبيق الإعدادات", isOn: styleBinding.custom)
                    .font(.subheadline.bold())
                    .tint(.brand)
            }
            Group {
                slider("التفاصيل", styleBinding.detail)
                slider("الغمقان", styleBinding.darkness)
                slider("السُمك", styleBinding.thickness)
                slider("تظليل", styleBinding.shading)
            }
            .disabled(locked)
            .opacity(locked ? 0.4 : 1)
            Button("رجّع الإعدادات الأفضل") {
                model.update { $0.style = $0.style.mode == .ai ? .aiStencil : .pencil }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .disabled(locked)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var heatPanel: some View {
        Text("حرارة الطباعة").font(.subheadline.bold())
        Picker("", selection: $density) {
            ForEach(Density.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(mode == .escpos)
        Text(density == .thick ? darkHeatWarning : "إذا طلعت الخطوط باهتة زيد الحرارة، وإذا انتشرت قللها.")
            .font(.caption)
            .foregroundStyle(density == .thick ? Color.brand : Color.secondary)
    }

    // MARK: - الطباعة

    private var printingCard: some View {
        VStack(spacing: 14) {
            Text("أطبع…").font(.headline)
            ProgressView(value: printer.progress ?? 0).tint(.brand)
            Button("إيقاف", role: .destructive) { printer.cancelPrint() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
    }

    private func printNow() {
        guard printer.isReady else { showPrinters = true; return }
        rendering = true
        Task {
            let bitmap = await model.renderForPrint(headWidth: mode.widthDots)
            rendering = false
            if let bitmap { printer.send(PrinterProtocol.job(bitmap, mode: mode, density: density)) }
        }
    }
}

// MARK: - الورقة

struct CanvasView: View {
    @ObservedObject var model: EditorModel
    @State private var dragStart: CGPoint?
    @State private var pinchStart: (width: CGFloat, rotation: Double)?
    @State private var resizeStart: CGFloat?
    private let ruler: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let s = max(0.1, min((geo.size.width - ruler - 4) / EditorModel.pageW,
                                 (geo.size.height - ruler - 8) / EditorModel.pageH))
            let size = CGSize(width: EditorModel.pageW * s, height: EditorModel.pageH * s)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: ruler, height: ruler)
                    Ruler(vertical: false, scale: s, length: EditorModel.pageW)
                        .frame(width: size.width, height: ruler)
                }
                HStack(alignment: .top, spacing: 0) {
                    Ruler(vertical: true, scale: s, length: EditorModel.pageH)
                        .frame(width: ruler, height: size.height)
                    page(s).frame(width: size.width, height: size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // الورقة مثل الورق الحقيقي: الصفر باليسار.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func page(_ s: CGFloat) -> some View {
        ZStack {
            Color.white
                .contentShape(Rectangle())
                .onTapGesture { model.selectedID = nil }
            ForEach(model.layers) { layer in
                layerView(layer, s)
            }
        }
        .clipped()
        .shadow(color: .black.opacity(0.12), radius: 6)
        .overlay { selectionOverlay(s) }
        .coordinateSpace(name: "page")
        .simultaneousGesture(
            MagnifyGesture().simultaneously(with: RotateGesture())
                .onChanged { value in
                    guard let i = model.selectedIndex else { return }
                    if pinchStart == nil { pinchStart = (model.layers[i].widthMM, model.layers[i].rotation) }
                    guard let start = pinchStart else { return }
                    if let m = value.first?.magnification {
                        model.layers[i].widthMM = min(400, max(5, start.width * m))
                    }
                    if let r = value.second?.rotation {
                        model.layers[i].rotation = start.rotation + r.degrees
                    }
                }
                .onEnded { _ in
                    pinchStart = nil
                    model.snapRotation()
                }
        )
    }

    private func layerView(_ layer: Layer, _ s: CGFloat) -> some View {
        let w = max(1, layer.widthMM * s), h = max(1, layer.heightMM * s)
        return ZStack {
            if let image = model.processed[layer.id]?.image {
                Image(uiImage: image).resizable()
            } else {
                Image(uiImage: layer.source).resizable().opacity(0.3)
                ProgressView()
            }
        }
        .frame(width: w, height: h)
        .scaleEffect(x: layer.mirrored ? -1 : 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = layer.id }
        .gesture(
            DragGesture(coordinateSpace: .named("page"))
                .onChanged { v in
                    guard let i = model.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                    if model.selectedID != layer.id { model.selectedID = layer.id }
                    if dragStart == nil { dragStart = model.layers[i].center }
                    guard let start = dragStart else { return }
                    model.layers[i].center = CGPoint(x: start.x + v.translation.width / s,
                                                     y: start.y + v.translation.height / s)
                }
                .onEnded { _ in dragStart = nil }
        )
        .rotationEffect(.degrees(layer.rotation))
        .position(x: layer.center.x * s, y: layer.center.y * s)
    }

    /// الإطار والأزرار على الصندوق المحيط بالصورة، وما يدورون ويّاها.
    @ViewBuilder
    private func selectionOverlay(_ s: CGFloat) -> some View {
        if let layer = model.selected {
            let b = model.bounds(layer)
            let r = CGRect(x: b.minX * s, y: b.minY * s, width: b.width * s, height: b.height * s)
            ZStack {
                Rectangle()
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .frame(width: max(1, r.width), height: max(1, r.height))
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
                handle("xmark")
                    .position(x: r.minX, y: r.minY)
                    .onTapGesture { model.delete() }
                handle("rotate.right")
                    .position(x: r.maxX, y: r.minY)
                    .onTapGesture { model.rotate90() }
                handle("arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .position(x: r.minX, y: r.maxY)
                    .onTapGesture { model.update { $0.mirrored.toggle() } }
                handle("arrow.up.left.and.arrow.down.right")
                    .position(x: r.maxX, y: r.maxY)
                    .gesture(resize(layer, s))
            }
        }
    }

    /// زر صغير بالشكل، بس مساحة اللمس كبيرة (44 نقطة) حتى ينضغط بسهولة.
    private func handle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.black))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func resize(_ layer: Layer, _ s: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("page"))
            .onChanged { v in
                guard let i = model.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                if resizeStart == nil { resizeStart = model.layers[i].widthMM }
                guard let start = resizeStart else { return }
                let c = CGPoint(x: layer.center.x * s, y: layer.center.y * s)
                let d0 = hypot(v.startLocation.x - c.x, v.startLocation.y - c.y)
                let d1 = hypot(v.location.x - c.x, v.location.y - c.y)
                guard d0 > 1 else { return }
                model.layers[i].widthMM = min(400, max(5, start * d1 / d0))
            }
            .onEnded { _ in resizeStart = nil }
    }
}

struct Ruler: View {
    let vertical: Bool
    let scale: CGFloat
    let length: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let labelEvery = scale * 10 >= 16 ? 10 : 20
            for mm in 0...Int(length) {
                let tick: CGFloat
                if mm % 10 == 0 { tick = 9 } else if mm % 5 == 0 { tick = 6 } else if scale >= 1.4 { tick = 3 } else { continue }
                let p = CGFloat(mm) * scale
                var path = Path()
                if vertical {
                    path.move(to: CGPoint(x: size.width, y: p))
                    path.addLine(to: CGPoint(x: size.width - tick, y: p))
                } else {
                    path.move(to: CGPoint(x: p, y: size.height))
                    path.addLine(to: CGPoint(x: p, y: size.height - tick))
                }
                ctx.stroke(path, with: .color(.gray), lineWidth: 0.6)
                if mm % labelEvery == 0 {
                    let label = Text("\(mm)").font(.system(size: 7)).foregroundColor(.gray)
                    if vertical {
                        ctx.draw(label, at: CGPoint(x: 1, y: p + 1), anchor: .topLeading)
                    } else {
                        ctx.draw(label, at: CGPoint(x: p + 1, y: 1), anchor: .topLeading)
                    }
                }
            }
        }
    }
}

// MARK: - القص

struct CropView: View {
    let image: UIImage
    @State var rect: NormRect
    let onDone: (NormRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: NormRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = fitted(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
                    overlay(fit)
                }
                .frame(width: fit.width, height: fit.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(24)
            .background(Color.black)
            .environment(\.layoutDirection, .leftToRight)
            .navigationTitle("قص الصورة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("تم") { onDone(rect); dismiss() }.bold() }
                ToolbarItem(placement: .bottomBar) { Button("الصورة كاملة") { rect = .full } }
            }
        }
    }

    private func fitted(in size: CGSize) -> CGSize {
        let s = min(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
        return CGSize(width: image.size.width * s, height: image.size.height * s)
    }

    private func overlay(_ size: CGSize) -> some View {
        let r = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.w * size.width, height: rect.h * size.height)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(drag(size) { s, dx, dy in
                    var n = s
                    n.x = min(max(0, s.x + dx), 1 - s.w)
                    n.y = min(max(0, s.y + dy), 1 - s.h)
                    return n
                })
            ForEach(0..<4, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .position(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                    .gesture(drag(size) { s, dx, dy in resizeCorner(corner, s, dx, dy) })
            }
        }
    }

    private func resizeCorner(_ corner: Int, _ s: NormRect, _ dx: Double, _ dy: Double) -> NormRect {
        var minX = s.x, minY = s.y, maxX = s.x + s.w, maxY = s.y + s.h
        let gap = 0.05
        if corner % 2 == 0 { minX = min(max(0, minX + dx), maxX - gap) } else { maxX = max(min(1, maxX + dx), minX + gap) }
        if corner < 2 { minY = min(max(0, minY + dy), maxY - gap) } else { maxY = max(min(1, maxY + dy), minY + gap) }
        return NormRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    private func drag(_ size: CGSize, _ apply: @escaping (NormRect, Double, Double) -> NormRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if start == nil { start = rect }
                guard let s = start else { return }
                rect = apply(s, v.translation.width / size.width, v.translation.height / size.height)
            }
            .onEnded { _ in start = nil }
    }
}

// MARK: - النص

struct TextSheet: View {
    @State var text: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(initial: String, onDone: @escaping (String) -> Void) {
        _text = State(initialValue: initial)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("اكتب النص", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
            }
            .navigationTitle("نص")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") {
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { onDone(clean) }
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear { focused = true }
        }
    }
}
