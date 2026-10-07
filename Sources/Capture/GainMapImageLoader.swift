import CoreImage
import ImageIO

// ゲインマップ付きの HEIC/JPEG から、SDR 版と HDR 版を読む（Debug の -JPSOpenImage 用）。
// 画面収録の権限なしで HDR 表示を確かめるための入口。
enum GainMapImageLoader {

    /// 共有の CIContext。作業空間は拡張リニア sRGB・float（1.0 超を潰さない）。
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh.rawValue,
    ])

    /// SDR 版（通常の読み込み）と HDR 版を返す。読めなければ nil。
    /// ゲインマップが無い（HDR 版が実質 SDR の）画像は hdr = nil。
    ///
    /// `HDRAvailability.resolve` は通すが、ディスプレイの余力は問わない（`.greatestFiniteMagnitude`）。
    /// 実機の撮影経路と同じ「1.0 超の画素があるか」の判定だけ使い、HDR 非対応ディスプレイでも
    /// 切替 UI の動作確認ができるようにするため（表示は自動で SDR に落ちる）。
    static func load(url: URL) -> (sdr: CGImage, hdr: CGImage?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sdr = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        guard let ci = CIImage(contentsOf: url, options: [.expandToHDR: true]),
              let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let hdr = context.createCGImage(
                  ci, from: ci.extent, format: .RGBAh, colorSpace: space),
              hdr.width == sdr.width, hdr.height == sdr.height
        else { return (sdr, nil) }
        return (sdr, HDRAvailability.resolve(hdr, displayMaxEDR: .greatestFiniteMagnitude))
    }
}
