import AppKit
import Testing

@testable import JPScreenShot

// 結果画面の SDR/HDR 切替（実装計画-HDR フェーズ3）。
@MainActor
@Suite("SDR/HDR 切替")
struct ResultViewModelHDRTests {

    private func makeSDR() -> CGImage {
        let context = HDRPixelFormat.makeContext(width: 40, height: 30, hdr: false)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return context.makeImage()!
    }

    /// 1.0 超の画素を含む HDR 版（拡張 sRGB・16bit float）。
    private func makeHDR() -> CGImage {
        let context = HDRPixelFormat.makeContext(width: 40, height: 30, hdr: true)!
        context.setFillColor(CGColor(
            colorSpace: HDRPixelFormat.hdrColorSpace!, components: [3, 3, 3, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return context.makeImage()!
    }

    @Test("HDR 版があれば既定は HDR")
    func defaultsToHDR() {
        let model = ResultViewModel(
            capture: CaptureResult(image: makeSDR(), scale: 1, hdrImage: makeHDR()))
        #expect(model.hasHDR)
        #expect(model.dynamicRange == .hdr)
    }

    @Test("HDR 版が無ければ SDR 固定で、HDR にできない")
    func sdrOnly() {
        let model = ResultViewModel(capture: CaptureResult(image: makeSDR(), scale: 1))
        #expect(!model.hasHDR)
        #expect(model.dynamicRange == .sdr)
        model.dynamicRange = .hdr
        #expect(model.dynamicRange == .sdr)
    }

    @Test("切り替えても注釈は保たれる")
    func annotationsSurviveSwitch() {
        let model = ResultViewModel(
            capture: CaptureResult(image: makeSDR(), scale: 1, hdrImage: makeHDR()))
        let before = model.editor.document.annotations
        model.dynamicRange = .sdr
        model.dynamicRange = .hdr
        #expect(model.editor.document.annotations == before)
        #expect(model.editor.redaction.isHDR)
    }

    @Test("BaseImageView は HDR で PQ 画像と .high、SDR で元画像と .standard")
    func baseImageViewLayers() {
        let sdr = makeSDR()
        let view = BaseImageView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        view.setImage(sdr, hdr: makeHDR())
        #expect(!view.isShowingHDR)

        view.setDynamicRange(.hdr)
        #expect(view.isShowingHDR)
        let baked = view.imageLayer.contents as! CGImage
        #expect(baked.colorSpace?.name == CGColorSpace.itur_2100_PQ)
        #expect(baked.bitsPerComponent == 16)
        #expect(view.imageLayer.preferredDynamicRange == .high)
        #expect(view.imageLayer.toneMapMode == .never)

        view.setDynamicRange(.sdr)
        #expect(!view.isShowingHDR)
        #expect(view.imageLayer.contents as! CGImage === sdr)
        #expect(view.imageLayer.preferredDynamicRange == .standard)

        // 再び HDR: 焼き直さず同じ画像を使う。
        view.setDynamicRange(.hdr)
        #expect(view.imageLayer.contents as! CGImage === baked)
    }

    @Test("HDR 版が無い BaseImageView は HDR を要求されても SDR のまま")
    func baseImageViewWithoutHDR() {
        let view = BaseImageView(frame: .zero)
        view.setImage(makeSDR())
        view.setDynamicRange(.hdr)
        #expect(!view.isShowingHDR)
    }
}
