import UIKit

enum ImageMode: String {
    case original   // الصورة على حالها
    case drawing    // رسم ستنسل أسود وأبيض
}

struct ImageStyle: Hashable {
    var mode: ImageMode = .original
    var lines = 0.5       // كثرة الخطوط والتفاصيل
    var thickness = 0.33  // سمك الخط
    var shading = 0.0     // تظليل المناطق الغامقة (صفر = خطوط بس، الأفضل للستنسل)

    /// أفضل إعدادات للستنسل: الخطوط الأساسية بس، بسمك واضح، وبدون تظليل.
    static let stencil = ImageStyle(mode: .drawing)
}

enum Filters {
    /// يرجع الصورة بالحجم المطلوب بالضبط. الرسم: نقاط سوداء على خلفية شفافة.
    static func process(_ source: CGImage, crop: NormRect, style: ImageStyle, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var image = source
        if crop != .full {
            let rect = CGRect(x: crop.x * Double(source.width), y: crop.y * Double(source.height),
                              width: crop.w * Double(source.width), height: crop.h * Double(source.height)).integral
            if let cropped = source.cropping(to: rect) { image = cropped }
        }
        if style.mode == .original { return scaled(image, width, height) }

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
        return mask(stencil(gray, width, height, style), width, height)
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

    // MARK: - الرسم (فرق غاوسيين، مثل رسم الستنسل)

    private static func stencil(_ g: [UInt8], _ w: Int, _ h: Int, _ s: ImageStyle) -> [Bool] {
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
        let sigma = max(0.6, (2.6 - 1.8 * Float(s.lines)) * scale)
        let g1 = blur(f, w, h, sigma)
        let g2 = blur(f, w, h, sigma * 1.6)
        let eps = -0.006 - 0.016 * Float(1 - s.lines)
        var out = [Bool](repeating: false, count: n)
        for i in 0..<n { out[i] = g1[i] - 0.985 * g2[i] < eps }

        // نشيل النقاط الصغيرة المتناثرة حتى يطلع الستنسل نظيف.
        removeSpecks(&out, w, h, minArea: max(6, Int(18 * scale * scale)))
        out = dilate(out, w, h, Int((s.thickness * 3 * Double(scale)).rounded()))

        if s.shading > 0 {
            let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { $0 / 16 }
            let cut = Float(0.25 + 0.45 * s.shading)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let tone = min(1, max(0, (cut - g1[i]) / cut))
                    if tone > bayer[(y & 3) * 4 + (x & 3)] + 0.05 { out[i] = true }
                }
            }
        }
        return out
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
