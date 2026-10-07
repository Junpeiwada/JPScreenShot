import CoreGraphics

// HDR（拡張 sRGB・16bit float）と SDR（8bit）の「合成用ビットマップの作り分け」を
// 1 か所に集める。影（ShadowCompositor）・注釈の焼き込み（AnnotationRenderer）・
// ぼかし／モザイク（RedactionRenderer）が同じ判定・同じ形式を使わないと、
// 層ごとに 8bit と 16bit が混ざって 1.0 超が潰れたり、色空間変換でずれたりする。
enum HDRPixelFormat {

    /// 元画像が HDR（浮動小数・16bit 以上）か。
    ///
    /// ScreenCaptureKit の hdrImage は拡張 sRGB の 16bit float。SDR 版は 8bit 整数。
    /// 値の範囲ではなくピクセル形式で見るのは、ここが「1.0 超を保持できる器が
    /// 要るか」を決めるだけで、実際に 1.0 超があるかは HDRAvailability の仕事だから。
    static func isHDR(_ image: CGImage) -> Bool {
        image.bitmapInfo.contains(.floatComponents) && image.bitsPerComponent >= 16
    }

    /// SDR 合成用の色空間。元画像が RGB モデルならその色空間、そうでなければ sRGB。
    ///
    /// DeviceRGB で合成すると、ディスプレイの色空間（Display P3 など）で撮った sdrImage の
    /// 色空間タグが落ち、書き出し・貼り付け先で色が変わって見える。元の色空間のまま描けば
    /// 値の変換が起きない。RGB 以外（グレースケール・CMYK など）はビットマップの描画先に
    /// できない（作成に失敗する）ので sRGB に落とす。
    static func sdrColorSpace(for image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    /// HDR 合成用の色空間（拡張 sRGB）。
    static var hdrColorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.extendedSRGB) }

    /// HDR 用の bitmapInfo（16bit float・RGBA・premultiplied）。
    static let hdrBitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue

    /// 合成用の描画先。HDR は拡張 sRGB の 16bit float、SDR は 8bit。
    /// - Parameter colorSpace: SDR のときの色空間（nil なら DeviceRGB）。HDR では無視して拡張 sRGB。
    static func makeContext(
        width: Int, height: Int, hdr: Bool, sdrColorSpace: CGColorSpace? = nil
    ) -> CGContext? {
        if hdr {
            guard let space = hdrColorSpace else { return nil }
            return CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16,
                bytesPerRow: 0, space: space, bitmapInfo: hdrBitmapInfo)
        }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: sdrColorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
