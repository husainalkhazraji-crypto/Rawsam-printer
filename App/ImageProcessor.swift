import UIKit

struct EditSettings: Equatable {
    var widthMM: Double = 100
    var rotation = 0              // 0, 90, 180, 270
    var mirrored = false
    var inverted = false
    var threshold: Double = 0.55  // كل ما زاد صارت الصورة أغمق
    var dither = false            // للتظليل والتدرجات
    var outline = false           // استخراج الخطوط من صورة
}

enum ImageProcessor {
    /// يحول الصورة إلى bitmap بعرض رأس الطابعة، والتصميم بالنص.
    static func render(_ image: UIImage, settings: EditSettings, headWidth: Int) -> Bitmap? {
        let turned = settings.rotation % 180 != 0
        let srcW = turned ? image.size.height : image.size.width
        let srcH = turned ? image.size.width : image.size.height
        guard srcW > 0, srcH > 0 else { return nil }

        var w = min(Double(headWidth), settings.widthMM * Double(PrinterProtocol.dotsPerMM))
        var h = w * Double(srcH / srcW)
        let limit = Double(PrinterProtocol.maxRows)
        if h > limit { w *= limit / h; h = limit }
        let width = max(8, Int(w.rounded()))
        let height = max(1, Int(h.rounded()))

        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // نقلب المحور حتى يرسم UIKit بالاتجاه الصحيح.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            if settings.mirrored { ctx.scaleBy(x: -1, y: 1) }
            ctx.rotate(by: CGFloat(settings.rotation) * .pi / 180)
            let dw = CGFloat(turned ? height : width)
            let dh = CGFloat(turned ? width : height)
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }

        if settings.outline { gray = edges(gray, width: width, height: height) }
        let mono = binarize(gray, width: width, height: height, settings: settings)

        var out = Bitmap(width: headWidth, height: height)
        let left = (headWidth - width) / 2
        for y in 0..<height {
            for x in 0..<width {
                out.pixels[y * headWidth + left + x] = mono[y * width + x]
            }
        }
        return out
    }

    /// مرشح Sobel: الحواف تصير غامقة والباقي أبيض.
    private static func edges(_ g: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: g.count)
        guard width > 2, height > 2 else { return g }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Int { Int(g[(y + dy) * width + x + dx]) }
                let right = p(1, -1) + 2 * p(1, 0) + p(1, 1)
                let leftSide = p(-1, -1) + 2 * p(-1, 0) + p(-1, 1)
                let bottom = p(-1, 1) + 2 * p(0, 1) + p(1, 1)
                let topSide = p(-1, -1) + 2 * p(0, -1) + p(1, -1)
                let magnitude = min(255, abs(right - leftSide) + abs(bottom - topSide))
                out[y * width + x] = UInt8(255 - magnitude)
            }
        }
        return out
    }

    private static func binarize(_ g: [UInt8], width: Int, height: Int, settings: EditSettings) -> [UInt8] {
        let cut = Float(settings.threshold * 255)
        var values = g.map { Float($0) }
        if settings.dither {
            // Floyd–Steinberg؛ شريط الغمقان يفتح ويغمق التدرج.
            let shift = Float((settings.threshold - 0.5) * 255)
            for i in values.indices where values[i] < 250 { values[i] -= shift }
        }
        var out = [UInt8](repeating: 0, count: g.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = values[i]
                let black = settings.dither ? old < 128 : old < cut
                out[i] = (black != settings.inverted) ? 1 : 0
                guard settings.dither else { continue }
                let error = old - (black ? 0 : 255)
                if x + 1 < width { values[i + 1] += error * 7 / 16 }
                if y + 1 < height {
                    if x > 0 { values[i + width - 1] += error * 3 / 16 }
                    values[i + width] += error * 5 / 16
                    if x + 1 < width { values[i + width + 1] += error / 16 }
                }
            }
        }
        return out
    }

    static func preview(_ bitmap: Bitmap) -> UIImage? {
        let bytes = Data(bitmap.pixels.map { $0 == 1 ? UInt8(0) : UInt8(255) })
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cg = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: bitmap.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
