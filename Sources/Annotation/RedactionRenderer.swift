import CoreGraphics
import CoreImage
import Foundation

// ぼかし・モザイクの画像を、元画像から作ってキャッシュする。
//
// 常に**元画像（注釈を描く前の画像）から**その範囲を計算し直す。注釈の上に
// 注釈を重ねて加工することはしない。重なり順が「元画像 → ぼかし・モザイク →
// 図形・テキスト」に固定なので、これで足りる。
//
// キャッシュは**注釈 ID ごとに最新の 1 件だけ**持つ。ドラッグ中は位置・大きさ・強さが
// 毎回変わるので、キーごとに溜めると際限なく増える。注釈が無くなったら `prune(keeping:)`
// で解放し、ウィンドウを閉じたら `removeAllCachedImages()` で全部解放する
// （Retina の大きな画像ではキャッシュが重い）。
@MainActor
final class RedactionRenderer {

    /// 加工済みの範囲 1 件。
    struct Piece {
        /// 加工後の画像（ピクセル寸法は `rect` × scale）。楕円形なら外側が透明。
        let image: CGImage
        /// 画像を置く範囲（ポイント座標。ピクセル境界に揃えてある）。
        let rect: CGRect
    }

    /// キャッシュのキー。範囲・種類・強さ・形で決まる（元画像はインスタンスで固定）。
    private struct Key: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let isMosaic: Bool
        let strength: Double
        let shape: RedactionShape
    }

    private let base: CGImage
    private let scale: CGFloat
    private let ciContext: CIContext
    /// 注釈 ID ごとの最新 1 件。
    private var cache: [UUID: (key: Key, image: CGImage)] = [:]

    /// 元画像が HDR（16bit float・拡張 sRGB）か。
    /// HDR のときは加工も float で行い、1.0 超を保つ（8bit 経由だと 1.0 に潰れる）。
    /// キャッシュの SDR/HDR 混在は、このレンダラが**ベース画像ごとのインスタンス**で
    /// `isHDR` がインスタンス固定であることで防ぐ（SDR 用・HDR 用は別インスタンス）。
    let isHDR: Bool

    /// 加工画像の色空間。元画像が RGB 以外（グレースケール・CMYK など）なら sRGB。
    /// RGB 以外ではビットマップを作れず、加工に失敗して範囲が素通しになるため。
    /// HDR のときは拡張 sRGB。
    private let outputColorSpace: CGColorSpace

    /// - Parameters:
    ///   - base: 元画像（注釈なし）。
    ///   - scale: 1 ポイントあたりのピクセル数（`CaptureResult.scale`）。
    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale > 0 ? scale : 1
        self.ciContext = CIContext()
        let hdr = HDRPixelFormat.isHDR(base)
        self.isHDR = hdr
        self.outputColorSpace =
            (hdr ? HDRPixelFormat.hdrColorSpace : nil)
            ?? HDRPixelFormat.sdrColorSpace(for: base)
    }

    /// キャッシュしている画像の数（テスト・確認用）。
    var cachedCount: Int { cache.count }

    /// キャッシュを破棄する。
    func removeAllCachedImages() {
        cache.removeAll()
        ciContext.clearCaches()
    }

    /// `ids` に含まれない注釈のキャッシュを捨てる。注釈の削除・作成ドラッグの破棄・
    /// 取り消しのあとに呼ぶ。
    func prune(keeping ids: Set<UUID>) {
        for id in cache.keys where !ids.contains(id) { cache[id] = nil }
    }

    /// 注釈（ぼかし・モザイク）の範囲を加工した画像。
    /// 範囲が画像の外に出ている・空のときは nil。
    func piece(for annotation: Annotation) -> Piece? {
        guard annotation.kind == .blur || annotation.kind == .mosaic else { return nil }
        return piece(
            id: annotation.id,
            rect: AnnotationGeometry.bounds(of: annotation),
            isMosaic: annotation.kind == .mosaic,
            // 下限未満の強さで描かない（読めてしまう事故を防ぐ。P4-5）。
            strength: annotation.style.redaction.clamped(for: annotation.kind).strength,
            shape: annotation.style.redaction.shape
        )
    }

    /// キャッシュしない版（ID を持たない呼び出し・テスト用）。
    func piece(rect: CGRect, isMosaic: Bool, strength: Double, shape: RedactionShape) -> Piece? {
        piece(id: nil, rect: rect, isMosaic: isMosaic, strength: strength, shape: shape)
    }

    private func piece(
        id: UUID?, rect: CGRect, isMosaic: Bool, strength: Double, shape: RedactionShape
    ) -> Piece? {
        // ポイント範囲を、画像内のピクセル境界へ丸める（外側へ切り上げて隙間を作らない）。
        let imageBounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let scaled = CGRect(
            x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale
        )
        let pixelRect = scaled.integral.intersection(imageBounds)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let placed = CGRect(
            x: pixelRect.minX / scale, y: pixelRect.minY / scale,
            width: pixelRect.width / scale, height: pixelRect.height / scale
        )
        let strength = max(1, strength)
        let key = Key(
            x: Int(pixelRect.minX), y: Int(pixelRect.minY),
            width: Int(pixelRect.width), height: Int(pixelRect.height),
            isMosaic: isMosaic, strength: strength, shape: shape
        )
        if let id, let cached = cache[id], cached.key == key {
            return Piece(image: cached.image, rect: placed)
        }

        // 加工に失敗しても範囲をそのまま見せない。不透明な灰色で塗りつぶして必ず隠す。
        let final: CGImage
        if let processed = process(pixelRect: pixelRect, isMosaic: isMosaic, strength: strength),
            let masked = shape == .ellipse ? maskedToEllipse(processed) : processed
        {
            final = masked
        } else if let filled = opaqueFill(
            width: Int(pixelRect.width), height: Int(pixelRect.height), ellipse: shape == .ellipse)
        {
            final = filled
        } else {
            return nil
        }
        if let id { cache[id] = (key, final) }
        return Piece(image: final, rect: placed)
    }

    // MARK: 内部

    private func process(pixelRect: CGRect, isMosaic: Bool, strength: Double) -> CGImage? {
        let source = CIImage(cgImage: base)
        // CGImage は左上原点、CIImage は左下原点。切り抜き範囲の y を反転する。
        let ciRect = CGRect(
            x: pixelRect.minX, y: CGFloat(base.height) - pixelRect.maxY,
            width: pixelRect.width, height: pixelRect.height
        )
        let amount = strength * Double(scale)

        let output: CIImage
        if isMosaic {
            // ブロックの格子を範囲の左下に合わせる（範囲を動かしても端が欠けたブロックに
            // ならない）。範囲外の画素を取り込むので端を延長してから使う。
            output = source.clampedToExtent().applyingFilter(
                "CIPixellate",
                parameters: [
                    kCIInputScaleKey: amount,
                    kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY),
                ])
        } else {
            // ガウスぼかしは範囲の外を透明として扱うので、そのままだと縁が暗くなる。
            // 端を延長（clampedToExtent）してからぼかし、最後に範囲で切り抜く。
            output = source.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: [kCIInputRadiusKey: amount])
        }
        return ciContext.createCGImage(
            output.cropped(to: ciRect), from: ciRect, format: isHDR ? .RGBAh : .RGBA8, colorSpace: outputColorSpace)
    }

    /// 楕円の外側を透明にする（楕円形のぼかし・モザイク）。
    private func maskedToEllipse(_ image: CGImage) -> CGImage? {
        guard
            let context = HDRPixelFormat.makeContext(
                width: image.width, height: image.height, hdr: isHDR,
                sdrColorSpace: outputColorSpace)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addEllipse(in: rect)
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 加工できなかったときの代わり。不透明な灰色（楕円なら外側は透明）。
    private func opaqueFill(width: Int, height: Int, ellipse: Bool) -> CGImage? {
        // HDR 版の上に 8bit の灰を重ねても見た目は成立するが、層の形式を揃えるため
        // HDR のときは float で作る（灰 0.5 は 1.0 を超えないので光らない）。
        guard
            let context = HDRPixelFormat.makeContext(
                width: width, height: height, hdr: isHDR,
                sdrColorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if ellipse {
            context.addEllipse(in: rect)
            context.clip()
        }
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(rect)
        return context.makeImage()
    }
}
