import Foundation

/// صورة بلونين: 1 = نقطة سوداء (تسخين)، 0 = أبيض.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
    }

    var rowBytes: Int { (width + 7) / 8 }

    /// 8 نقاط بكل بايت، والبت الأعلى هو النقطة اليسرى.
    func packedRow(_ y: Int) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: rowBytes)
        for x in 0..<width where pixels[y * width + x] == 1 {
            row[x >> 3] |= 0x80 >> UInt8(x & 7)
        }
        return row
    }
}

enum Density: String, CaseIterable, Identifiable {
    case low, normal, medium, thick
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "خفيف"
        case .normal: return "عادي"
        case .medium: return "وسط"
        case .thick: return "غامق"
        }
    }
}

/// طرق الإرسال. طريقتا MHT مأخوذة من توثيق طابعة MHT-500 (نفس الشركة)،
/// وطريقة ESC/POS احتياطية. ولا وحدة منها مجربة بعد على MHT-P19.
enum PrintMode: String, CaseIterable, Identifiable {
    case mhtLegacy, mhtNew, escpos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mhtLegacy: return "MHT (١)"
        case .mhtNew: return "MHT (٢)"
        case .escpos: return "ESC/POS"
        }
    }
    var widthDots: Int {
        switch self {
        case .mhtLegacy: return 1680
        case .mhtNew, .escpos: return 1664
        }
    }
}

enum PrinterProtocol {
    static let dotsPerMM = 8
    static let maxRows = 2376   // طول A4 = 297 ملم
    static let queryModel: [UInt8] = [0x10, 0x04, 0x06]
    static let queryFirmware: [UInt8] = [0x10, 0x04, 0x08]

    static func setup(mode: PrintMode, density: Density) -> [UInt8] {
        var out: [UInt8] = [0x1B, 0x40]
        guard mode != .escpos else { return out }
        let new = mode == .mhtNew
        let heat: UInt8
        switch density {
        case .low: heat = new ? 100 : 130
        case .normal: heat = new ? 120 : 160
        case .medium: heat = new ? 135 : 175
        case .thick: heat = new ? 150 : 190
        }
        let settings: [(UInt8, UInt8)] = [(1, new ? 8 : 16), (2, 100), (3, 1), (4, new ? 4 : 2), (5, 0), (6, heat)]
        for (key, value) in settings {
            out += [0x1F, 0xFD, 0x01, key, value]
        }
        return out
    }

    static func job(_ bitmap: Bitmap, mode: PrintMode, density: Density) -> Data {
        precondition(bitmap.rowBytes <= 255, "عرض الصورة أكبر من المسموح")
        var out = setup(mode: mode, density: density)
        switch mode {
        case .mhtLegacy, .mhtNew:
            for y in 0..<bitmap.height {
                out += [0x16, UInt8(bitmap.rowBytes)]
                out += bitmap.packedRow(y)
                out += [0x15, 0x01]
            }
            out += [0x0A, 0x0A, 0x0A, 0x1F, 0x01, 0x06]
        case .escpos:
            // GS v 0 على شكل شرائط حتى لا تمتلئ ذاكرة الطابعة.
            var y = 0
            while y < bitmap.height {
                let rows = min(128, bitmap.height - y)
                out += [0x1D, 0x76, 0x30, 0x00, UInt8(bitmap.rowBytes), 0x00, UInt8(rows & 0xFF), UInt8(rows >> 8)]
                for r in y..<(y + rows) { out += bitmap.packedRow(r) }
                y += rows
            }
            out += [0x0A, 0x0A, 0x0A]
        }
        return Data(out)
    }

    /// مستطيل اختبار 40×20 ملم حتى تتأكد من القياس الحقيقي.
    static func calibration(width: Int) -> Bitmap {
        var b = Bitmap(width: width, height: 256)
        let left = (width - 320) / 2, top = 32
        func fill(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
            for y in y1...y2 { for x in x1...x2 { b.pixels[y * width + x] = 1 } }
        }
        fill(left, top, left + 319, top + 1)
        fill(left, top + 158, left + 319, top + 159)
        fill(left, top, left + 1, top + 159)
        fill(left + 318, top, left + 319, top + 159)
        fill(left + 156, top + 75, left + 163, top + 84)
        for mm in stride(from: 0, through: 40, by: 10) {
            let x = left + min(mm * 8, 319)
            fill(x, 208, x, 223)
        }
        fill(left, 223, left + 319, 223)
        return b
    }
}
