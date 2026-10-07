import Foundation
import CoreGraphics
import Testing

@testable import JPScreenShot

// HDR ベース（拡張 sRGB・16bit float）での注釈の焼き込み・ぼかし・モザイクの確認（実装計画-HDR P2-4）。
// 画面権限は要らない（メモリ上のビットマップだけ）。
@MainActor
@Suite("注釈の書き出し（HDR）")
struct AnnotationRendererHDRTests {

    /// 全面が同じ値（`level` ＝ 1.0 が SDR 白。2.0 なら SDR 白の 2 倍の明るさ）の HDR 画像。
    private func makeHDR(width: Int, height: Int, level: CGFloat = 2.0) -> CGImage {
        let context = HDRPixelFormat.makeContext(width: width, height: height, hdr: true)!
        context.setFillColor(
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, components: [level, level, level, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeSDRWhite(width: Int, height: Int) -> CGImage {
        let context = HDRPixelFormat.makeContext(
            width: width, height: height, hdr: false, sdrColorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 1 画素の R 成分（float）。画像を拡張 sRGB の float コンテキストへ描いて読む（左上原点）。
    private func red(_ image: CGImage, x: Int, y: Int) -> Float {
        let context = HDRPixelFormat.makeContext(width: image.width, height: image.height, hdr: true)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: Float16.self)
        // CGContext の data は上の行が先頭（描画座標は左下原点だが、メモリは上から）。
        let i = y * (context.bytesPerRow / MemoryLayout<Float16>.size) + x * 4
        return Float(data[i])
    }

    private func whiteRect() -> Annotation {
        var rect = Annotation(kind: .rect, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60))
        rect.style.fill = .solid
        rect.style.color = RGBAColor(red: 1, green: 1, blue: 1)
        rect.style.shadow.isOn = false
        return rect
    }

    @Test("HDR ベース: 出力は 16bit float で、注釈の無い画素は 1.0 超を保つ")
    func 注釈なしの画素() throws {
        let base = makeHDR(width: 100, height: 80)
        let output = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [whiteRect()]))
        #expect(output.bitsPerComponent == 16)
        #expect(output.bitmapInfo.contains(.floatComponents))
        #expect(output.width == 100 && output.height == 80)
        #expect(abs(red(output, x: 90, y: 70) - 2.0) < 0.01)
    }

    @Test("HDR ベース: 白い注釈は 1.0 のまま光らない（1.0 を超えない）")
    func 白い注釈は光らない() throws {
        let base = makeHDR(width: 100, height: 80)
        let output = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [whiteRect()]))
        let value = red(output, x: 40, y: 40)
        #expect(abs(value - 1.0) < 0.01, "白の注釈の値は \(value)")
    }

    @Test("SDR ベースは従来どおり 8bit")
    func SDRは8bit() throws {
        let base = makeSDRWhite(width: 100, height: 80)
        let output = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [whiteRect()]))
        #expect(output.bitsPerComponent == 8)
        #expect(!output.bitmapInfo.contains(.floatComponents))
    }

    @Test("HDR ベース: ぼかし・モザイクとも 1.0 超を保ち、結果は float")
    func 加工は1超を保つ() throws {
        let base = makeHDR(width: 100, height: 80, level: 3.0)
        let renderer = RedactionRenderer(base: base, scale: 1)
        #expect(renderer.isHDR)
        for isMosaic in [false, true] {
            for shape in [RedactionShape.rectangle, .ellipse] {
                let piece = try #require(
                    renderer.piece(
                        rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                        isMosaic: isMosaic, strength: 8, shape: shape))
                #expect(piece.image.bitsPerComponent == 16)
                #expect(piece.image.bitmapInfo.contains(.floatComponents))
                // 楕円でも中心は不透明で加工済み。
                #expect(red(piece.image, x: 20, y: 20) > 2.5, "mosaic=\(isMosaic) shape=\(shape)")
            }
        }
    }

    @Test("HDR ベースへ焼き込んだぼかしも 1.0 超を保つ")
    func 焼き込みのぼかし() throws {
        let base = makeHDR(width: 100, height: 80, level: 3.0)
        var blur = Annotation(kind: .blur, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60))
        blur.style.redaction.strength = 6
        let output = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [blur]))
        #expect(output.bitsPerComponent == 16)
        #expect(red(output, x: 40, y: 40) > 2.5)
    }

    @Test("エディタは SDR/HDR の加工キャッシュを別々に持ち、寸法違いの HDR は使わない")
    func エディタの差し替え口() throws {
        let sdr = makeSDRWhite(width: 100, height: 80)
        let hdr = makeHDR(width: 100, height: 80)
        let name = "AnnotationRendererHDRTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = AnnotationStyleStore(defaults: defaults)
        let editor = AnnotationEditor(base: sdr, scale: 1, hdrBase: hdr, styleStore: store)
        #expect(editor.hasHDR)
        #expect(!editor.redaction.isHDR)
        editor.dynamicRange = .hdr
        #expect(editor.redaction.isHDR)

        let mismatched = AnnotationEditor(
            base: sdr, scale: 1, hdrBase: makeHDR(width: 50, height: 40), styleStore: store)
        #expect(!mismatched.hasHDR)
        mismatched.dynamicRange = .hdr
        #expect(mismatched.dynamicRange == .sdr)
    }
}
