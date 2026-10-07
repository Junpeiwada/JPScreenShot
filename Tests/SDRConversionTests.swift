import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// HDR ソースから SDR 版を作る変換（1.0 超だけ色相保持で切り詰める）。
@Suite("SDR 版の生成")
struct SDRConversionTests {

    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// 拡張リニア sRGB の 16bit float 単色画像（値は 1.0 超も可）。
    private func makeSource(
        _ r: Float, _ g: Float, _ b: Float, alpha: Float = 1, space: CGColorSpace = SDRConversionTests.linear
    ) -> CGImage {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 16, bytesPerRow: 0,
            space: space, bitmapInfo: info)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [
            CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(alpha),
        ])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    /// 画像を拡張リニア sRGB の float へ描き直して先頭画素を読む（プレマルチの値。不透明ならストレートと同じ）。
    private func read(_ image: CGImage, space: CGColorSpace = SDRConversionTests.linear) -> [Float] {
        var px = [Float](repeating: 0, count: 4 * image.width * image.height)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 32, bytesPerRow: image.width * 16,
                space: space, bitmapInfo: info)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let a = px[3]
        return a > 0 ? [px[0] / a, px[1] / a, px[2] / a, a] : px
    }

    private func convert(
        _ r: Float, _ g: Float, _ b: Float, alpha: Float = 1, to space: CGColorSpace = SDRConversionTests.p3
    ) -> CGImage? {
        try? SDRConversion.makeSDR(from: makeSource(r, g, b, alpha: alpha), colorSpace: space)
    }

    @Test("1.0 以下の灰色と P3 内の色は値が変わらない")
    func sdrRangeUnchanged() throws {
        for v: Float in [0.5, 1.0] {
            let out = try #require(convert(v, v, v))
            let px = read(out)
            for c in 0..<3 { #expect(abs(px[c] - v) <= 1.5 / 255) }
        }
        // 出力（Display P3）で 1.0 以下の色。ソースはリニア sRGB で与えているので、値は色変換を経て
        // P3 になる（変換後も 1.0 以下なので切り詰めの対象外＝値は変わらない）。
        let color: [Float] = [0.8, 0.3, 0.1]
        let px = read(try #require(convert(color[0], color[1], color[2])))
        // 読み戻しもリニア sRGB なので、往復して元の値に戻る。
        for c in 0..<3 { #expect(abs(px[c] - color[c]) <= 2 / 255) }
    }

    @Test("(4,4,4) は白になる")
    func brightGrayBecomesWhite() throws {
        let px = read(try #require(convert(4, 4, 4)))
        for c in 0..<3 { #expect(abs(px[c] - 1) <= 1.5 / 255) }
    }

    @Test("(4,2,1) は色相を保って (1,0.5,0.25) になる")
    func hueKept() throws {
        // 色相保持の比は作業空間（リニア Display P3）で取るので、P3 リニアで与えて読む。
        let p3Linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let src = makeSource(4, 2, 1, space: p3Linear)
        let out = try SDRConversion.makeSDR(from: src, colorSpace: p3Linear)
        let px = read(out, space: p3Linear)
        #expect(abs(px[0] - 1) <= 2 / 255)
        #expect(abs(px[1] - 0.5) <= 2 / 255)
        #expect(abs(px[2] - 0.25) <= 2 / 255)
    }

    @Test("出力は 8bit・指定した色空間")
    func outputFormat() throws {
        let out = try #require(convert(0.5, 0.5, 0.5))
        #expect(out.bitsPerComponent == 8)
        #expect(!out.bitmapInfo.contains(.floatComponents))
        #expect(out.colorSpace?.name == Self.p3.name)
        // P3 以外でも出力は指定した空間になる。
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        #expect(try #require(convert(0.5, 0.5, 0.5, to: srgb)).colorSpace?.name == srgb.name)
        #expect(out.width == 4 && out.height == 4)
    }

    @Test("アルファを保つ")
    func alphaKept() throws {
        let px = read(try #require(convert(0.5, 0.5, 0.5, alpha: 0.5)))
        #expect(abs(px[3] - 0.5) <= 2 / 255)
        #expect(abs(px[0] - 0.5) <= 3 / 255)
    }

    // 半透明で 1.0 を超える画素のテストは置かない（2026-10-07 に削除）。撮影画像は不透明で、
    // ウィンドウの影は SDR 化の後に付けるため、この経路に半透明の HDR 画素は来ない。8bit・ガンマ空間の
    // プレマルチ値を読み戻す検証が成り立たず、実際に来ない入力のために複雑さを足さない判断。

    @Test("m>1 で負の成分を含む色も、比を保って切り詰める")
    func negativeComponentKeepsRatio() throws {
        // リニア sRGB (2.0, 0.5, -0.2) → sRGB 出力。m=2 なので (1, 0.25, -0.1)。負は 8bit で 0 に丸まる。
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let px = read(try #require(convert(2.0, 0.5, -0.2, to: srgb)))
        #expect(abs(px[0] - 1) <= 2 / 255, "r=\(px[0])")
        #expect(abs(px[1] - 0.25) <= 0.02, "g=\(px[1])")
        #expect(px[2] <= 0.01, "b=\(px[2])")
    }

    /// 出力空間（sRGB・BT.2020）のリニア版で、1.0 以下は不変・1.0 超は色相保持で max=1 になること。
    @Test("切り詰めは出力色空間で成り立つ（sRGB・BT.2020）", arguments: [CGColorSpace.sRGB as String, CGColorSpace.itur_2020 as String])
    func clampInOutputSpace(name: String) throws {
        let out = try #require(CGColorSpace(name: name as CFString))
        let linearOut = try #require(CGColorSpaceCreateExtendedLinearized(out))
        // (入力: リニア sRGB)。1 つ目は出力でも 1.0 以下、残りは 1.0 を超える。
        for src: [Float] in [[0.4, 0.3, 0.1], [1.6, 1.0, 0.4], [3, 3, 3], [0.2, 1.5, 0.3]] {
            let image = try #require(convert(src[0], src[1], src[2], to: out))
            #expect(image.colorSpace?.name == out.name)
            let px = read(image, space: linearOut)
            // 期待値: 入力を出力のリニア空間へ変換 → max>1 なら max で割る。
            let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let color = CGColor(colorSpace: linearSRGB, components: [
                CGFloat(src[0]), CGFloat(src[1]), CGFloat(src[2]), 1])!
            let comps = try #require(
                color.converted(to: linearOut, intent: .defaultIntent, options: nil)?.components)
            let m = max(1, Float(comps[0]), Float(comps[1]), Float(comps[2]))
            for c in 0..<3 {
                #expect(abs(px[c] - Float(comps[c]) / m) <= 0.02,
                        "\(name) src=\(src) ch\(c): \(px[c]) vs \(Float(comps[c]) / m)")
                #expect(px[c] <= 1 + 0.02)
            }
        }
    }

    @Test("float でないソースは SDR としてそのまま使う")
    func planForEightBit() throws {
        let ctx = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: Self.p3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        #expect(SDRConversion.plan(for: ctx.makeImage()!) == .useAsSDR)
        #expect(SDRConversion.plan(for: makeSource(1, 1, 1)) == .convertFromHDR)
    }
}
