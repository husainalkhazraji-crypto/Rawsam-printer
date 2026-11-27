import Foundation

func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); exit(1) }
    print("ok: \(what)")
}

check(PrinterProtocol.setup(mode: .mhtLegacy, density: .normal) ==
      [0x1B,0x40, 0x1F,0xFD,1,1,16, 0x1F,0xFD,1,2,100, 0x1F,0xFD,1,3,1, 0x1F,0xFD,1,4,2, 0x1F,0xFD,1,5,0, 0x1F,0xFD,1,6,160],
      "legacy setup bytes")
var b = Bitmap(width: 16, height: 1)
b.pixels[0] = 1; b.pixels[15] = 1
check(b.packedRow(0) == [0x80, 0x01], "bit order")
let mht = [UInt8](PrinterProtocol.job(b, mode: .mhtNew, density: .low))
check(Array(mht.dropFirst(32)) == [0x16,2,0x80,0x01,0x15,0x01, 0x0A,0x0A,0x0A,0x1F,0x01,0x06], "row framing")
// أطوال مهمة الاختبار الموثقة للبروتوكول المرجعي
check(PrinterProtocol.job(PrinterProtocol.calibration(width: 1680), mode: .mhtLegacy, density: .low).count == 54822, "legacy job length")
check(PrinterProtocol.job(PrinterProtocol.calibration(width: 1664), mode: .mhtNew, density: .low).count == 54310, "new job length")
let tall = Bitmap(width: 1664, height: 300)
check(PrinterProtocol.job(tall, mode: .escpos, density: .low).count == 2 + 3 * 8 + 208 * 300 + 3, "escpos strips")
