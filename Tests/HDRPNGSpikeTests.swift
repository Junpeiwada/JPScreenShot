import CoreGraphics
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import JPScreenShot

// 実装計画-HDR P1-1: 16bit・ITU-R 2100 PQ の HDR PNG が書けて、読み戻しても
// 色空間・ビット深度・1.0 超の明部が残るかの検証（スパイク）。
//
// 結果画面の「PNG で保存」の HDR 版はこの書き出しに依存する。残らないなら
// PNG 方針を見直すことになるので、API ごとに分けて結果を固定しておく。
@Suite("HDR PNG の書き出し検証")
struct HDRPNGSpikeTests {

    /// 拡張 sRGB・16bit float（1.0 = SDR 白）の画像。左半分は 0.5、右半分は 4.0。
    private func makeExtendedImage() -> CGImage {
        let width = 8, height = 4
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.5, 0.5, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        context.setFillColor(CGColor(colorSpace: space, components: [4, 4, 4, 1])!)
        context.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    /// 読み戻した画像の最大 R 符号値（0〜1）。同じ PQ 空間の 16bit 整数に描き直して測る
    /// （色空間が同じなので変換は入らず、PQ の符号値がそのまま取れる）。
    private func maxPQCode(_ image: CGImage) -> Double {
        let space = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        var pixels = [UInt16](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 16, bytesPerRow: image.width * 8, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var maxValue: UInt16 = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { maxValue = max(maxValue, pixels[i]) }
        return Double(maxValue) / 65535
    }

    private func readBack(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// PQ 符号値で SDR 白 203nit 相当（約 0.58）。これより上があれば 1.0 超が残っている。
    private let sdrWhiteCode = 0.58

    @Test("CIContext.pngRepresentation(.RGBA16, itur_2100_PQ) で書くと PQ・16bit・明部が残る")
    func ciContextPNG() throws {
        let ci = CIImage(cgImage: makeExtendedImage())
        let space = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let data = try #require(
            CIContext().pngRepresentation(of: ci, format: .RGBA16, colorSpace: space))
        let image = try #require(readBack(data))
        let name = image.colorSpace?.name as String?
        print("HDRPNG[CIContext] 色空間=\(name ?? "nil") bpc=\(image.bitsPerComponent) 最大PQ符号=\(maxPQCode(image))")
        #expect(name == (CGColorSpace.itur_2100_PQ as String))
        #expect(image.bitsPerComponent == 16)
        #expect(maxPQCode(image) > sdrWhiteCode)
    }
}
