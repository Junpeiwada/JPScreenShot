import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// HDR 版が実質 SDR かの判定（実装計画-HDR P1-6）。
@Suite("HDR 版の有無判定")
struct HDRAvailabilityTests {

    @Test("最大値が 1.0 以下なら HDR 無し")
    func sdrOnly() {
        #expect(!HDRAvailability.isEffectivelyHDR(maxLuminance: 1.0, displayMaxEDR: 4))
        #expect(!HDRAvailability.isEffectivelyHDR(maxLuminance: 1.005, displayMaxEDR: 4))
    }

    @Test("1.0 を許容分より超える画素があれば HDR あり")
    func hdr() {
        #expect(HDRAvailability.isEffectivelyHDR(maxLuminance: 1.5, displayMaxEDR: 4))
    }

    @Test("ディスプレイの EDR 余力が 1.0 なら画素が明るくても HDR 無し")
    func displayWithoutHeadroom() {
        #expect(!HDRAvailability.isEffectivelyHDR(maxLuminance: 3, displayMaxEDR: 1.0))
    }

    private static let bitmapInfo =
        CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue

    /// 実際の hdrImage と同じ、ガンマ付きの拡張 sRGB（16bit float）で単色画像を作る。
    private func makeImage(color: (CGColorSpace) -> CGColor) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: Self.bitmapInfo)!
        context.setFillColor(color(space))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private func makeImage(value: CGFloat) -> CGImage {
        makeImage { CGColor(colorSpace: $0, components: [value, value, value, 1])! }
    }

    /// Display P3 の純赤を拡張 sRGB に描いたもの（SDR 範囲だが拡張 sRGB では R≈1.22）。
    private func makeP3RedImage() -> CGImage {
        makeImage { _ in
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1])!
        }
    }

    @Test("画像の最大値を 1.0 超でも頭打ちにせず測れる")
    func measuresAboveOne() throws {
        let measured = try #require(HDRAvailability.maxLuminance(of: makeImage(value: 3)))
        // 灰色なので輝度 = リニア値（係数の和は 1）。画像はガンマ付きの拡張 sRGB なので、
        // 符号化値 3 は sRGB の逆ガンマで ((3 + 0.055) / 1.055)^2.4 のリニア値になる。
        let linear = Float(pow((3 + 0.055) / 1.055, 2.4))
        #expect(abs(measured - linear) / linear < 0.01)
    }

    @Test("P3 の純赤（SDR 範囲）は成分が 1.0 を超えても HDR と誤判定しない")
    func wideGamutIsNotHDR() throws {
        let image = makeP3RedImage()
        let measured = try #require(HDRAvailability.maxLuminance(of: image))
        #expect(measured < 1.0)
        #expect(HDRAvailability.resolve(image, displayMaxEDR: 4) == nil)
    }

    @Test("拡張 sRGB で 2.0 の白は HDR あり")
    func brightWhiteIsHDR() {
        #expect(HDRAvailability.resolve(makeImage(value: 2), displayMaxEDR: 4) != nil)
    }

    @Test("resolve: 明部のある画像は残り、SDR 範囲の画像と EDR 余力なしは nil")
    func resolve() {
        #expect(HDRAvailability.resolve(makeImage(value: 3), displayMaxEDR: 4) != nil)
        #expect(HDRAvailability.resolve(makeImage(value: 0.8), displayMaxEDR: 4) == nil)
        #expect(HDRAvailability.resolve(makeImage(value: 3), displayMaxEDR: 1) == nil)
        #expect(HDRAvailability.resolve(nil, displayMaxEDR: 4) == nil)
    }
}
