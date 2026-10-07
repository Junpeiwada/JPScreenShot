import CoreImage
import Foundation

// HDR 画像から SDR 版を自前で作る。
//
// 実測（2026-10-07）: `SCScreenshotManager.captureScreenshot` に `.bothSDRAndHDR` を指定すると
// sdrImage にも hdrImage にも**同じ HDR 画像**（16bit float・拡張 sRGB）が返る。
// `.sdr` 単独は色空間 nil、`.hdr` 単独は HDR 画像が sdrImage 側に入る。そのため API の SDR 版は使えず、
// HDR ソースから作る。
//
// 方式: 1.0 を超えた画素だけ色相（RGB 比）を保って切り詰める（m = max(r,g,b) > 1 なら rgb /= m）。
// 1.0 以下の画素（UI・文字）は値を変えない。HDR 写真の明部は白く飛ぶ（許容済み）。
// CIToneMapHeadroom は SDR の白そのものを 0.51 まで落とすので使わない（実測）。
//
// ★切り詰めは「出力の色空間（ディスプレイ ICC）のリニア版」で行う。
// 作業空間（リニア P3）で切り詰めると、出力が BT.2020 や sRGB のとき、P3 では 1.0 以下でも
// 出力空間では 1.0 を超える成分が残り、8bit 化の段で色空間側に丸められて色相がずれる。
// 出力空間で max(r,g,b) ≤ 1 にしておけば、書き出し時に範囲外の成分が出ない。
// ただし `CGColorSpace` の線形化は行列ベースの空間でしか成り立たない（LUT 型の ICC では nil）。
// そのときは作業空間（拡張リニア Display P3）での切り詰めに落とす。この場合は出力空間で
// 1.0 を超える成分が残り得る（範囲外は 8bit 化で丸められる）。これは既知の制約。
enum SDRConversionError: LocalizedError, Equatable {
    /// 切り詰めカーネル（Metal）を読めない。
    case kernelUnavailable
    /// カーネルは読めたが、描画（色変換・CGImage 化）に失敗した。
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .kernelUnavailable: "色変換カーネルを読み込めません。"
        case .renderFailed: "SDR 画像の描画に失敗しました。"
        }
    }
}

enum SDRConversion {

    /// 作業空間は拡張リニア Display P3・float。1.0 超や負値を潰さず、色相保持の比がリニアで正しく取れる。
    /// CIContext はスレッドセーフ（Sendable）なので、複数スレッドから共有してよい。
    private static let workingSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private static let context = CIContext(options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAf.rawValue,
    ])

    /// カーネル。読めなければ nil。
    ///
    /// ★読めないとき `makeSDR` は `kernelUnavailable` を投げ、単純なクランプ（CIColorClamp 等）には落とさない。
    /// 単純クランプは色相が変わる別の絵になり、黙って違う絵を SDR 版として出してしまうため。
    /// 呼び出し側（ScreenCaptureService）が撮影エラーとして利用者へ伝える。
    private static let kernel: CIColorKernel? = MetalKernelLibrary.colorKernel("jpsHueKeepClamp")

    /// HDR 画像から SDR 版（8bit RGBA・premultipliedLast・`colorSpace`）を作る。
    /// - Parameter colorSpace: 出力の色空間（ディスプレイの色空間）。切り詰めはこの空間のリニア版で行う
    ///   （線形化できない空間では作業空間で行う。ファイル冒頭の説明を参照）。
    /// - Throws: `SDRConversionError`（カーネルが読めない／描画に失敗）。
    static func makeSDR(from hdr: CGImage, colorSpace: CGColorSpace) throws -> CGImage {
        guard let kernel else { throw SDRConversionError.kernelUnavailable }
        let input = CIImage(cgImage: hdr)

        // 出力空間の拡張リニア版（範囲を ±∞ にして 1.0 超・負値を保つ）。取れなければ作業空間のまま。
        let linearOutput = CGColorSpaceCreateExtendedLinearized(colorSpace)
        let source: CIImage
        if let linearOutput {
            guard let moved = input.matchedFromWorkingSpace(to: linearOutput) else {
                throw SDRConversionError.renderFailed
            }
            source = moved
        } else {
            source = input
        }

        guard var clamped = kernel.apply(extent: source.extent, arguments: [source]) else {
            throw SDRConversionError.renderFailed
        }
        if let linearOutput {
            guard let back = clamped.matchedToWorkingSpace(from: linearOutput) else {
                throw SDRConversionError.renderFailed
            }
            clamped = back
        }
        guard let image = context.createCGImage(
            clamped, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw SDRConversionError.renderFailed }
        return image
    }

    /// 撮影結果から (SDR 版の素, HDR ソース) の扱いを決める純粋関数。
    enum Plan: Equatable {
        /// float の HDR ソースあり。SDR 版は `makeSDR` で作り、HDR 版は判定してから使う。
        case convertFromHDR
        /// ソースが float でない（Intel Mac などで 8bit が来た）。そのまま SDR 版とし、HDR 版は無し。
        case useAsSDR
    }

    static func plan(for source: CGImage) -> Plan {
        source.bitmapInfo.contains(.floatComponents) && source.bitsPerComponent > 8
            ? .convertFromHDR : .useAsSDR
    }
}
