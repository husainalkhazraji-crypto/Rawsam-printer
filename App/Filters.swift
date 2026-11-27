import UIKit

enum ImageMode: String {
    case original   // الصورة على حالها
    case drawing    // رسم قلم رصاص (خطوط)
    case ai         // رسم بالذكاء الاصطناعي داخل التلفون
}

struct ImageStyle: Hashable {
    var mode: ImageMode = .original
    var detail = 0.5      // التفاصيل: كثرة الخطوط
    var darkness = 0.5    // الغمقان: تغميق أو تفتيح الخطوط
    var thickness = 0.2   // السمك
    var shading = 0.0     // تظليل بالنقاط مثل قلم الرصاص (صفر = خطوط بس، الأفضل للستنسل)

    static let pencil = ImageStyle(mode: .drawing)
    static let aiStencil = ImageStyle(mode: .ai)
}

enum Filters {
    static func cropped(_ source: CGImage, _ crop: NormRect) -> CGImage {
        guard crop != .full else { return source }
        let rect = CGRect(x: crop.x * Double(source.width), y: crop.y * Double(source.height),
                          width: crop.w * Double(source.width), height: crop.h * Double(source.height)).integral
        return source.cropping(to: rect) ?? source
    }

    /// يرجع الصورة بالحجم المطلوب بالضبط. الرسم: نقاط سوداء على خلفية شفافة.
    /// `ai`: رسم النموذج للصورة المقصوصة (مطلوب بوضع AI بس).
    static func process(_ source: CGImage, ai: CGImage?, crop: NormRect, style: ImageStyle, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let image = cropped(source, crop)
        let scale = Float(max(width, height)) / 1000
        switch style.mode {
        case .original:
            return scaled(image, width, height)
        case .drawing:
            guard let gray = grayPixels(image, width, height) else { return nil }
            let sketch = pencil(gray, width, height, detail: style.detail)
            let cut = Float(0.76 + 0.18 * clamp01(style.darkness))
            var black = sketch.map { $0 < cut }
            removeSpecks(&black, width, height, minArea: max(4, Int(8 * scale * scale)))
            finish(&black, sketch, width, height, style)
            return mask(black, width, height)
        case .ai:
            guard let ai, let lines = grayPixels(ai, width, height) else { return nil }
            let cut = UInt8(80 + 110 * clamp01(style.darkness))
            var black = lines.map { $0 < cut }
            let area = (6 + 30 * (1 - clamp01(style.detail))) * Double(scale * scale)
            removeSpecks(&black, width, height, minArea: max(4, Int(area)))
            let sketch = style.shading > 0 ? grayPixels(image, width, height).map { pencil($0, width, height, detail: 0.5) } : nil
            finish(&black, sketch, width, height, style)
            return mask(black, width, height)
        }
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func grayPixels(_ image: CGImage, _ width: Int, _ height: Int) -> [UInt8]? {
        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? gray : nil
    }

    /// رسم قلم رصاص: الصورة مقسومة على عكسها المغبّش (Color Dodge).
    /// النتيجة رمادية من 0 (أسود) إلى 1 (أبيض).
    private static func pencil(_ g: [UInt8], _ w: Int, _ h: Int, detail: Double) -> [Float] {
        let scale = Float(max(w, h)) / 1000
        let sigma = max(1, (2 + 10 * Float(clamp01(detail))) * scale)
        let gray = g.map { Float($0) / 255 }
        let blurredInverse = fastBlur(gray.map { 1 - $0 }, w, h, sigma)
        var out = [Float](repeating: 1, count: gray.count)
        for i in gray.indices {
            out[i] = min(1, gray[i] / max(1 - blurredInverse[i], 0.001))
        }
        return out
    }

    /// السمك والتظليل: نفسها للرسم العادي ورسم الـ AI.
    private static func finish(_ out: inout [Bool], _ sketch: [Float]?, _ w: Int, _ h: Int, _ s: ImageStyle) {
        let scale = Float(max(w, h)) / 1000
        out = dilate(out, w, h, Int((s.thickness * 3 * Double(scale)).rounded()))
        guard s.shading > 0, let sketch else { return }
        let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { $0 / 16 }
        let gamma = Float(1 + 5 * s.shading)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if powf(sketch[i], gamma) < bayer[(y & 3) * 4 + (x & 3)] { out[i] = true }
            }
        }
    }

    /// الصورة الأصلية بخلفية بيضاء.
    private static func scaled(_ image: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func removeSpecks(_ b: inout [Bool], _ w: Int, _ h: Int, minArea: Int) {
        var seen = [Bool](repeating: false, count: b.count)
        var stack: [Int] = []
        var component: [Int] = []
        for start in 0..<b.count where b[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true)
            component.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            while let p = stack.popLast() {
                component.append(p)
                let x = p % w, y = p / w
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w || (dx == 0 && dy == 0) { continue }
                        let q = yy * w + xx
                        if b[q] && !seen[q] { seen[q] = true; stack.append(q) }
                    }
                }
            }
            if component.count < minArea { for p in component { b[p] = false } }
        }
    }

    private static func dilate(_ b: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        guard r > 0 else { return b }
        var tmp = [Bool](repeating: false, count: b.count)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where b[row + x] {
                for xx in max(0, x - r)...min(w - 1, x + r) { tmp[row + xx] = true }
            }
        }
        var out = [Bool](repeating: false, count: b.count)
        for y in 0..<h {
            for x in 0..<w where tmp[y * w + x] {
                for yy in max(0, y - r)...min(h - 1, y + r) { out[yy * w + x] = true }
            }
        }
        return out
    }

    /// تغبيش سريع للقيم الكبيرة: نصغّر، نغبّش، ونرجع نكبّر.
    private static func fastBlur(_ src: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
        let f = Int(sigma / 2)
        guard f >= 2 else { return blur(src, w, h, sigma) }
        let sw = (w + f - 1) / f, sh = (h + f - 1) / f
        var small = [Float](repeating: 0, count: sw * sh)
        var count = [Float](repeating: 0, count: sw * sh)
        for y in 0..<h {
            let sy = y / f
            for x in 0..<w {
                let i = sy * sw + x / f
                small[i] += src[y * w + x]
                count[i] += 1
            }
        }
        for i in small.indices { small[i] /= max(count[i], 1) }
        let b = blur(small, sw, sh, sigma / Float(f))
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) / Float(f) - 0.5
            let y0 = max(0, min(sh - 1, Int(fy.rounded(.down))))
            let y1 = min(sh - 1, y0 + 1)
            let ty = max(0, min(1, fy - Float(y0)))
            for x in 0..<w {
                let fx = (Float(x) + 0.5) / Float(f) - 0.5
                let x0 = max(0, min(sw - 1, Int(fx.rounded(.down))))
                let x1 = min(sw - 1, x0 + 1)
                let tx = max(0, min(1, fx - Float(x0)))
                let top = b[y0 * sw + x0] * (1 - tx) + b[y0 * sw + x1] * tx
                let bottom = b[y1 * sw + x0] * (1 - tx) + b[y1 * sw + x1] * tx
                out[y * w + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    private static func blur(_ src: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: 2 * r + 1)
        var sum: Float = 0
        for i in -r...r {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            kernel[i + r] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                kernel.withUnsafeBufferPointer { k in
                    for y in 0..<h {
                        let row = y * w
                        for x in 0..<w {
                            var acc: Float = 0
                            for j in -r...r {
                                let xx = min(w - 1, max(0, x + j))
                                acc += s[row + xx] * k[j + r]
                            }
                            t[row + x] = acc
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                kernel.withUnsafeBufferPointer { k in
                    for y in 0..<h {
                        for x in 0..<w {
                            var acc: Float = 0
                            for j in -r...r {
                                let yy = min(h - 1, max(0, y + j))
                                acc += t[yy * w + x] * k[j + r]
                            }
                            o[y * w + x] = acc
                        }
                    }
                }
            }
        }
        return out
    }

    private static func mask(_ black: [Bool], _ w: Int, _ h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where black[i] { px[i * 4 + 3] = 255 }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum TextRenderer {
    static func image(_ text: String) -> UIImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 160, weight: .bold),
                                                         .foregroundColor: UIColor.black,
                                                         .paragraphStyle: paragraph]
        let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let bounds = string.boundingRect(with: CGSize(width: 4000, height: 4000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let size = CGSize(width: max(bounds.width, 20) + 24, height: max(bounds.height, 20) + 24)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            string.draw(with: CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}
