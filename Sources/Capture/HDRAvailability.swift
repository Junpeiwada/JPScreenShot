import CoreImage

// HDR 版の画像が「実質 SDR」かを判定する（実装計画-HDR P1-6）。
//
// なぜ判定が要るのか:
// `SCScreenshotConfiguration.dynamicRange = .bothSDRAndHDR` は、HDR 非対応の
// ディスプレイや、HDR 対応でも画面に明るい部分が無い場面でも hdrImage を返す
// ことがある（拡張 sRGB で 0〜1.0 に収まっているだけの画像）。それを「HDR 版あり」
// として結果画面の SDR/HDR 切替に出すと、切り替えても見た目が変わらない
// ボタンが出てしまう。そこで画素の最大輝度を測り、1.0 を超える画素が
// 無ければ HDR 無し（hdrImage = nil）として扱う。
enum HDRAvailability {

    /// 1.0 を「超えた」とみなす余裕。
    ///
    /// 拡張 sRGB への変換や 16bit float の丸めで、SDR のみの画像でも最大値が
    /// 1.0 ちょうどにならず 1.000x になることがある。それを HDR と誤判定しない
    /// ための許容。実際の HDR 明部（SDR 白の 1.5 倍以上など）はこれより遥かに大きい。
    static let epsilon: Float = 0.01

    /// 画素の最大輝度とディスプレイの余力から、HDR 版が意味を持つかを返す純粋関数。
    /// - Parameters:
    ///   - maxLuminance: HDR 版画像の全画素の最大輝度（1.0 = SDR 白）。
    ///   - displayMaxEDR: ディスプレイの `maximumPotentialExtendedDynamicRangeColorComponentValue`。
    ///     1.0 なら EDR の余力が無く、HDR を表示できない。
    static func isEffectivelyHDR(
        maxLuminance: Float,
        displayMaxEDR: CGFloat
    ) -> Bool {
        guard displayMaxEDR > 1.0 else { return false }
        return maxLuminance > 1.0 + epsilon
    }

    /// 測定用の CIContext。撮影ごとに作らず共有する（生成が重く、GPU 資源も持つため）。
    /// CIContext はスレッドセーフ（Sendable）なので、複数スレッドから使ってよい。
    /// 作業空間は拡張リニア sRGB・float。8bit や sRGB クランプの作業空間だと 1.0 超が潰れる。
    private static let measureContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf.rawValue,
    ])

    /// 画像の輝度（リニア sRGB の Y）の最大値を測る（1.0 = SDR 白）。測れなければ nil。
    ///
    /// ★RGB 成分の最大値ではなく**輝度**で測る。hdrImage は拡張 sRGB だが、ディスプレイが
    /// Display P3 のとき、SDR 範囲の鮮やかな色（P3 の純赤など）は拡張 sRGB に直すと
    /// R が 1.0 を超える（P3 純赤 → R≈1.22）。成分最大値だと、HDR の明部が無いのに
    /// 「HDR あり」と誤判定してしまう。輝度は色域に依存せず、P3 の純色でも SDR 範囲なら
    /// 1.0 を超えない（白の 1.0 が上限）一方、HDR の明部は輝度が 1.0 を超える。
    /// 係数は Rec.709 / sRGB の Y = 0.2126R + 0.7152G + 0.0722B。作業空間がリニアなので
    /// ガンマの掛け直し無しにそのまま掛けられる。
    ///
    /// CIAreaMaximum で 1×1 に縮約し、浮動小数のまま読み出す。8bit 経由にすると
    /// 1.0 で頭打ちになり HDR の明部が見えなくなる。
    static func maxLuminance(of image: CGImage) -> Float? {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let input = CIImage(cgImage: image)
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        guard let matrix = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: input,
            "inputRVector": luma,
            "inputGVector": luma,
            "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]), let gray = matrix.outputImage,
            let filter = CIFilter(name: "CIAreaMaximum", parameters: [
                kCIInputImageKey: gray,
                kCIInputExtentKey: CIVector(cgRect: input.extent),
            ]), let output = filter.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            measureContext.render(
                output, toBitmap: buffer.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf, colorSpace: linear)
        }
        return pixel[0]
    }

    /// HDR 版が実質 SDR なら nil、意味があればそのまま返す。
    static func resolve(_ hdrImage: CGImage?, displayMaxEDR: CGFloat) -> CGImage? {
        guard let hdrImage, displayMaxEDR > 1.0,
              let maxValue = maxLuminance(of: hdrImage),
              isEffectivelyHDR(maxLuminance: maxValue, displayMaxEDR: displayMaxEDR)
        else { return nil }
        return hdrImage
    }
}
