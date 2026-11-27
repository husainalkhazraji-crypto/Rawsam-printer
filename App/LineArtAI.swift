import CoreML
import CoreImage
import UIKit

/// نموذج AI صغير داخل التطبيق يحول الصورة لرسم خطوط.
/// يشتغل بالتلفون نفسه: بدون إنترنت، بدون حساب، ومجاني لكل المستخدمين.
enum LineArtAI {
    private static let url = Bundle.main.url(forResource: "LineArt", withExtension: "mlmodelc")
    static var available: Bool { url != nil }

    /// النموذج يشتغل على مربع ثابت بهذا الحجم.
    static let side = 768

    private static var models: [MLComputeUnits: MLModel] = [:]
    private static let lock = NSLock()
    private static let context = CIContext()

    struct AIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func model(_ units: MLComputeUnits) throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let cached = models[units] { return cached }
        guard let url else { throw AIError(message: "النموذج مو موجود بالتطبيق") }
        let config = MLModelConfiguration()
        config.computeUnits = units
        let loaded = try MLModel(contentsOf: url, configuration: config)
        models[units] = loaded
        return loaded
    }

    /// يرجع رسم رمادي (خطوط غامقة على أبيض) بنفس نسبة أبعاد الصورة.
    static func draw(_ image: CGImage) -> Result<CGImage, Error> {
        // نحط الصورة بالنص على مربع أبيض.
        let scale = Double(side) / Double(max(image.width, image.height, 1))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        let x = (side - w) / 2, y = (side - h) / 2
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return .failure(AIError(message: "ما گدرت أجهز الصورة"))
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        // أصل CGContext من تحت.
        ctx.draw(image, in: CGRect(x: x, y: side - y - h, width: w, height: h))
        guard let square = ctx.makeImage() else { return .failure(AIError(message: "ما گدرت أجهز الصورة")) }

        var lastError: Error = AIError(message: "خطأ غير معروف")
        // نجرب كل المعالجات، وإذا فشل نرجع للمعالج العادي.
        for units in [MLComputeUnits.all, .cpuOnly] {
            do {
                let model = try model(units)
                let input = try MLFeatureValue(cgImage: square, pixelsWide: side, pixelsHigh: side,
                                               pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
                let output = try model.prediction(from: provider)
                guard let buffer = output.featureValue(for: "lines")?.imageBufferValue else {
                    throw AIError(message: "النموذج ما رجّع صورة")
                }
                let result = CIImage(cvPixelBuffer: buffer)
                let crop = CGRect(x: x, y: side - y - h, width: w, height: h)
                guard let lines = context.createCGImage(result.cropped(to: crop), from: crop) else {
                    throw AIError(message: "ما گدرت أقرا نتيجة النموذج")
                }
                return .success(lines)
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }
}
