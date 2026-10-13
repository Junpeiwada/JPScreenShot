import CoreGraphics
import ScreenCaptureKit
import Testing

@testable import JPScreenShot

// Intel Mac の全透明キャプチャ対策（dynamicRange の選択と全透明の判定）。
@Suite("全透明キャプチャの対策")
struct CaptureFallbackTests {

    /// 16bit float・拡張 sRGB の単色画像（Intel で返る全透明画像と同じ形式）。
    private func makeImage(alpha: CGFloat, width: Int = 8, height: Int = 6) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
            space: space, bitmapInfo: info)!
        if alpha > 0 {
            ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, alpha])!)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ctx.makeImage()!
    }

    @Test("HDR を表示できない画面では .sdr、できる画面では .bothSDRAndHDR")
    func dynamicRangeByDisplay() {
        #expect(CaptureFallback.dynamicRange(displayMaxEDR: 1.0) == .sdr)
        #expect(CaptureFallback.dynamicRange(displayMaxEDR: 0) == .sdr)
        #expect(CaptureFallback.dynamicRange(displayMaxEDR: 2.0) == .bothSDRAndHDR)
    }

    @Test("全画素 alpha 0 の画像は全透明と判定する")
    func detectsFullyTransparent() {
        #expect(CaptureFallback.isFullyTransparent(makeImage(alpha: 0)))
    }

    @Test("不透明・半透明の画像は全透明と判定しない")
    func opaqueIsNotTransparent() {
        #expect(!CaptureFallback.isFullyTransparent(makeImage(alpha: 1)))
        #expect(!CaptureFallback.isFullyTransparent(makeImage(alpha: 0.5)))
    }

    @Test("1 画素だけ不透明でも全透明と判定しない")
    func singleOpaquePixel() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: 50, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 37, y: 21, width: 1, height: 1))
        #expect(!CaptureFallback.isFullyTransparent(ctx.makeImage()!))
    }
}
