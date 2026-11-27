import SwiftUI

/// عنصر على ورقة الطباعة (صورة أو نص). القياسات بالملم.
struct Layer: Identifiable {
    var id = UUID()
    var source: UIImage
    var text: String?
    var center: CGPoint
    var widthMM: CGFloat
    var rotation: Double = 0
    var mirrored = false
    var crop = NormRect.full
    var style = ImageStyle()
    var version = 0

    var aspect: CGFloat {
        let w = source.size.width * crop.w, h = source.size.height * crop.h
        return w > 0 ? h / w : 1
    }
    var heightMM: CGFloat { widthMM * aspect }

    var key: ProcessKey {
        ProcessKey(id: id, crop: crop, style: style, version: version,
                   px: min(2400, max(8, Int((widthMM * 8).rounded()))))
    }
}

struct ProcessKey: Hashable {
    let id: UUID
    let crop: NormRect
    let style: ImageStyle
    let version: Int
    let px: Int
}

struct Processed {
    let key: ProcessKey
    let image: UIImage
}

@MainActor
final class EditorModel: ObservableObject {
    static let pageW: CGFloat = 210
    static let pageH: CGFloat = 297
    static let dotsPerMM: CGFloat = 8

    @Published var layers: [Layer] = []
    @Published var selectedID: UUID?
    @Published private(set) var processed: [UUID: Processed] = [:]
    @Published private(set) var aiWorking = false
    @Published var aiFailed = false
    /// رسم الـ AI لكل صورة ومنطقة قص (ثقيل، فنحسبه مرة وحدة).
    private var aiMaps: [AIKey: CGImage] = [:]

    private struct AIKey: Hashable {
        let id: UUID
        let crop: NormRect
        let version: Int
    }

    var selectedIndex: Int? { layers.firstIndex { $0.id == selectedID } }
    var selected: Layer? { selectedIndex.map { layers[$0] } }

    func update(_ change: (inout Layer) -> Void) {
        guard let i = selectedIndex else { return }
        change(&layers[i])
    }

    func add(image: UIImage) {
        let img = image.normalized()
        var layer = Layer(source: img, center: .zero, widthMM: 120)
        layer.widthMM = min(150, 200 / max(layer.aspect, 0.01))
        layer.center = CGPoint(x: Self.pageW / 2, y: 15 + layer.heightMM / 2)
        layers.append(layer)
        selectedID = layer.id
    }

    func addText(_ text: String) {
        var layer = Layer(source: TextRenderer.image(text), text: text, center: .zero, widthMM: 80)
        layer.widthMM = min(180, max(30, CGFloat(text.count) * 12))
        layer.center = CGPoint(x: Self.pageW / 2, y: 20 + layer.heightMM / 2)
        layers.append(layer)
        selectedID = layer.id
    }

    func updateText(_ text: String) {
        update {
            let oldHeight = $0.heightMM
            $0.text = text
            $0.source = TextRenderer.image(text)
            $0.version += 1
            $0.widthMM = oldHeight / max($0.aspect, 0.01)   // نحافظ على حجم الحروف
        }
    }

    func duplicate() {
        guard var copy = selected else { return }
        copy.id = UUID()
        copy.center.x += 8
        copy.center.y += 8
        layers.append(copy)
        selectedID = copy.id
    }

    func delete() {
        layers.removeAll { $0.id == selectedID }
        selectedID = nil
    }

    func rotate90() {
        update { $0.rotation = ($0.rotation + 90).truncatingRemainder(dividingBy: 360) }
    }

    func snapRotation() {
        update {
            var r = $0.rotation.truncatingRemainder(dividingBy: 360)
            if r < 0 { r += 360 }
            let nearest = (r / 90).rounded() * 90
            if abs(r - nearest) < 4 { r = nearest.truncatingRemainder(dividingBy: 360) }
            $0.rotation = r
        }
    }

    /// المربع المحيط بالعنصر بعد التدوير، بالملم.
    func bounds(_ l: Layer) -> CGRect {
        let a = l.rotation * .pi / 180
        let c = abs(cos(a)), s = abs(sin(a))
        let w = l.widthMM * c + l.heightMM * s
        let h = l.widthMM * s + l.heightMM * c
        return CGRect(x: l.center.x - w / 2, y: l.center.y - h / 2, width: w, height: h)
    }

    // MARK: - تجهيز الصور بالأبيض والأسود

    func processPending() async {
        for layer in layers {
            let key = layer.key
            if processed[layer.id]?.key == key { continue }
            guard let cg = layer.source.cgImage else { continue }
            let height = min(3400, max(1, Int((CGFloat(key.px) * layer.aspect).rounded())))
            var ai: CGImage?
            if key.style.mode == .ai {
                let aiKey = AIKey(id: layer.id, crop: key.crop, version: key.version)
                if let cached = aiMaps[aiKey] {
                    ai = cached
                } else {
                    aiWorking = true
                    let crop = key.crop
                    let drawn = await Task.detached(priority: .userInitiated) {
                        LineArtAI.draw(Filters.cropped(cg, crop))
                    }.value
                    aiWorking = false
                    if Task.isCancelled { return }
                    guard let drawn else {
                        aiFailed = true
                        if let i = layers.firstIndex(where: { $0.id == layer.id }) { layers[i].style = .stencil }
                        return
                    }
                    aiMaps[aiKey] = drawn
                    ai = drawn
                }
            }
            let aiMap = ai
            let result = await Task.detached(priority: .userInitiated) {
                Filters.process(cg, ai: aiMap, crop: key.crop, style: key.style, width: key.px, height: height)
            }.value
            if Task.isCancelled { return }
            if let result { processed[layer.id] = Processed(key: key, image: UIImage(cgImage: result)) }
        }
        let alive = Set(layers.map(\.id))
        processed = processed.filter { alive.contains($0.key) }
    }

    // MARK: - الطباعة

    /// يرسم الورقة كلها من الأعلى لحد آخر عنصر، بعرض رأس الطابعة.
    func renderForPrint(headWidth: Int) async -> Bitmap? {
        await processPending()
        guard !layers.isEmpty else { return nil }
        let dots = Self.dotsPerMM
        let leftMM = (Self.pageW - CGFloat(headWidth) / dots) / 2
        let bottom = layers.map { bounds($0).maxY }.max() ?? 0
        guard bottom > 0 else { return nil }
        let height = max(8, Int((min(Self.pageH, bottom + 3) * dots).rounded()))
        let width = headWidth

        var items: [(Layer, CGImage)] = []
        for l in layers {
            if let cg = processed[l.id]?.image.cgImage { items.append((l, cg)) }
        }
        var gray = [UInt8](repeating: 255, count: width * height)
        let ok = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // نخلي الإحداثيات من فوق لجوة مثل الشاشة.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            for (layer, image) in items {
                ctx.saveGState()
                ctx.translateBy(x: (layer.center.x - leftMM) * dots, y: layer.center.y * dots)
                ctx.rotate(by: layer.rotation * .pi / 180)
                if layer.mirrored { ctx.scaleBy(x: -1, y: 1) }
                ctx.scaleBy(x: 1, y: -1)
                let w = layer.widthMM * dots, h = layer.heightMM * dots
                ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            return true
        }
        guard ok else { return nil }
        return Bitmap(width: width, height: height, pixels: gray.map { $0 < 128 ? 1 : 0 })
    }
}
