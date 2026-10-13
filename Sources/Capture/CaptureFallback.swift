import CoreImage
import ScreenCaptureKit

// Intel Mac で撮った画像が全透明（結果ウィンドウでは真っ白）になる不具合への対策。
//
// 実測（2026-10-13、Intel i9-9980HK・外部 2560×1440 ×2・倍率 1x・maxEDR 1.0）:
// `dynamicRange` を `.bothSDRAndHDR` / `.hdr` にして width/height を指定すると、等倍の指定でも
// 全画素が alpha 0 の画像が返る。width/height を省けば写るが、Retina で等倍を保証できないので省けない。
// `.sdr` なら等倍指定で正しく写る。この環境では hdrImage は常に nil（16bit float が sdrImage に入る）。
//
// 対策は二段:
// 1. HDR を表示できない画面（maxEDR ≤ 1）では最初から `.sdr` で撮る。HDR 版はどうせ
//    `HDRAvailability` が捨てるので失うものは無い。
// 2. それでも全透明が返ったら `.sdr` で撮り直す（EDR 対応画面の Intel 機など、1 で避けられない環境の保険）。
enum CaptureFallback {

    /// 撮影時の `dynamicRange`。HDR を表示できない画面では `.sdr`。
    static func dynamicRange(displayMaxEDR: CGFloat) -> SCScreenshotConfiguration.DynamicRange {
        displayMaxEDR > 1.0 ? .bothSDRAndHDR : .sdr
    }

    /// 測定用の CIContext（共有。色管理は不要なので作業空間なし）。
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// 全画素が透明か。測れなければ false（撮り直さない）。
    ///
    /// CIAreaMaximum で 1×1 に縮約し、alpha の最大値だけを見る。
    static func isFullyTransparent(_ image: CGImage) -> Bool {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaMaximum", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return false }

        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                output, toBitmap: buffer.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf, colorSpace: nil)
        }
        return pixel[3] <= 0
    }
}
