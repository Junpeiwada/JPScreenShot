import CoreGraphics
import Testing

@testable import JPScreenShot

// 影の合成が HDR（1.0 超）を潰さないこと（実装計画-HDR P1-5）。
@Suite("影の合成と HDR")
struct ShadowCompositorHDRTests {

    private func makeHDRImage(value: CGFloat) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [value, value, value, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }

    private func makeSDRImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }

    /// 画像の (x, y)（左上原点・ピクセル）の R 成分を、拡張 sRGB の 16bit float で読み戻す。
    private func readRed(_ image: CGImage, x: Int, y: Int) -> Float {
        let context = HDRPixelFormat.makeContext(width: image.width, height: image.height, hdr: true)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: Float16.self)
        return Float(pixels[(y * context.bytesPerRow / 2) + x * 4])
    }

    @Test("HDR 入力は 16bit float のまま、影の無い画素が入力値（3.0）と等しい")
    func hdrPreserved() {
        let result = ShadowCompositor.addShadow(to: makeHDRImage(value: 3), scale: 1)
        #expect(result.bitsPerComponent == 16)
        #expect(result.bitmapInfo.contains(.floatComponents))
        #expect(result.width > 16 && result.height > 16)
        // 元画像は左右とも margin(56)、上は margin、下は margin + offsetY の位置に置かれる。
        // 画像の中央（影が重ならない・本体を上書きした画素）が入力と一致すること。
        let center = readRed(result, x: 56 + 8, y: 56 + 8)
        #expect(abs(center - 3.0) < 0.01)
    }

    @Test("SDR 入力は従来どおり 8bit")
    func sdrStays8bit() {
        let result = ShadowCompositor.addShadow(to: makeSDRImage(), scale: 1)
        #expect(result.bitsPerComponent == 8)
        #expect(!result.bitmapInfo.contains(.floatComponents))
    }
}
