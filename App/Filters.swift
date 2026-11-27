import UIKit

enum ImageMode: String, CaseIterable, Identifiable {
    case lines, mono, dither
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: return "خطوط"
        case .mono: return "أبيض وأسود"
        case .dither: return "تظليل"
        }
    }
}

struct ImageStyle: Hashable {
    var mode: ImageMode = .mono
    var threshold = 0.5   // أبيض وأسود والتظليل: كل ما زاد صار أغمق
    var detail = 0.5      // الخطوط: كثرة التفاصيل
    var weight = 0.5      // الخطوط: غمقان الخط
    var fill = 0.0        // الخطوط: تعبئة المناطق الغامقة
}

enum Filters {
    /// يرجع صورة شفافة بنقاط سوداء، بالحجم المطلوب بالضبط.
    static func process(_ source: CGImage, crop: NormRect, style: ImageStyle, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var image = source
        if crop != .full {
            let rect = CGRect(x: crop.x * Double(source.width), y: crop.y * Double(source.height),
                              width: crop.w * Double(source.width), height: crop.h * Double(source.height)).integral
            if let cropped = source.cropping(to: rect) { image = cropped }
        }
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
        guard drawn else { return nil }

        let black: [Bool]
        switch style.mode {
        case .mono:
            let cut = UInt8(max(1, min(254, style.threshold * 255)))
            black = gray.map { $0 < cut }
        case .dither:
            black = dither(gray, width, height, style.threshold)
        case .lines:
            black = lines(gray, width, height, style)
        }
        return mask(black, width, height)
    }

    /// صورة فوتوغرافية (بيها رمادي كثير) لو رسمة خطوط؟
    static func looksLikePhoto(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 64
        var gray = [UInt8](repeating: 255, count: side * side)
        gray.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let mid = gray.filter { $0 > 50 && $0 < 205 }.count
        return Double(mid) / Double(gray.count) > 0.3
    }

    // MARK: - الخطوط (فرق غاوسيين، مثل رسم الستنسل)

    private static func lines(_ g: [UInt8], _ w: Int, _ h: Int, _ s: ImageStyle) -> [Bool] {
        let n = w * h
        var hist = [Int](repeating: 0, count: 256)
        for v in g { hist[Int(v)] += 1 }
        func percentile(_ p: Double) -> Int {
            let target = Int(Double(n) * p)
            var acc = 0
            for i in 0..<256 { acc += hist[i]; if acc >= target { return i } }
            return 255
        }
        let lo = Float(percentile(0.01))
        let hi = max(Float(percentile(0.99)), lo + 1)
        let f = g.map { min(1, max(0, (Float($0) - lo) / (hi - lo))) }

        let scale = Float(max(w, h)) / 1000
        let sigma = max(0.6, (3.0 - 2.2 * Float(s.detail)) * scale)
        let g1 = blur(f, w, h, sigma)
        let g2 = blur(f, w, h, sigma * 1.6)
        let eps = -0.002 - 0.02 * Float(1 - s.weight)
        let fillCut = Float(s.fill) * 0.5
        var out = [Bool](repeating: false, count: n)
        for i in 0..<n {
            out[i] = g1[i] - 0.985 * g2[i] < eps || g1[i] < fillCut
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

    // MARK: - التظليل (Floyd–Steinberg)

    private static func dither(_ g: [UInt8], _ w: Int, _ h: Int, _ threshold: Double) -> [Bool] {
        let shift = Float((threshold - 0.5) * 255)
        var v = g.map { $0 < 250 ? Float($0) - shift : Float($0) }
        var out = [Bool](repeating: false, count: g.count)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = v[i]
                let black = old < 128
                out[i] = black
                let e = old - (black ? 0 : 255)
                if x + 1 < w { v[i + 1] += e * 7 / 16 }
                if y + 1 < h {
                    if x > 0 { v[i + w - 1] += e * 3 / 16 }
                    v[i + w] += e * 5 / 16
                    if x + 1 < w { v[i + w + 1] += e / 16 }
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
