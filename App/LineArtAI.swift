import CoreML
import CoreImage
import UIKit

/// نموذج AI صغير داخل التطبيق يحول الصورة لرسم خطوط.
/// يشتغل بالتلفون نفسه: بدون إنترنت، بدون حساب، ومجاني لكل المستخدمين.
enum LineArtAI {
    private static let url = Bundle.main.url(forResource: "LineArt", withExtension: "mlmodelc")
    static var available: Bool { url != nil }

    private static let model: MLModel? = {
        guard let url else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    private static let context = CIContext()

    /// يرجع رسم رمادي (خطوط غامقة على أبيض) بنفس نسبة أبعاد الصورة.
    static func draw(_ image: CGImage) -> CGImage? {
        guard let model else { return nil }
        // النموذج يشتغل على مربع، فنحط الصورة بالنص على خلفية بيضاء.
        let side = 768
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        let x = (side - w) / 2, y = (side - h) / 2
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        // CGContext أصله تحت، فنحسب مكان الصورة من تحت.
        ctx.draw(image, in: CGRect(x: x, y: side - y - h, width: w, height: h))
        guard let square = ctx.makeImage(),
              let input = try? MLFeatureValue(cgImage: square, pixelsWide: side, pixelsHigh: side,
                                              pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]),
              let output = try? model.prediction(from: provider),
              let buffer = output.featureValue(for: "lines")?.imageBufferValue else { return nil }
        let result = CIImage(cvPixelBuffer: buffer)
        // نقص المربع ونرجع بس منطقة الصورة (إحداثيات CIImage من تحت).
        let crop = CGRect(x: x, y: side - y - h, width: w, height: h)
        return context.createCGImage(result.cropped(to: crop), from: crop)
    }
}
