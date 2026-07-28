import AppKit

// ウィンドウキャプチャにドロップシャドウを合成する（CAP-07）。
//
// なぜ自前で描くのか（実測に基づく判断）:
//
// ScreenCaptureKit には `SCStreamConfiguration.ignoreShadowsSingleWindow` が
// あり、これを false にすれば影付きで撮れる。しかし影を含めると撮影範囲が
// ウィンドウ枠より外側に広がるのに、`SCContentFilter.contentRect` は
// 影を含まない範囲（= SCWindow.frame と同一）を返す。
// 実際の撮影範囲が分からないままサイズを指定するため、広い内容が狭い
// ピクセル数に押し込められて縮小され、目に見えてぼやける。
//
//   影なし: 鮮明度 7.684（整数 sourceRect と同水準）
//   影あり: 鮮明度 4.625  ← 過去にぼやけを踏んだ 5.132 より更に悪い
//
// そこで **影なしで等倍・鮮明に撮り、影はここで合成する**。
// 鮮明度を一切犠牲にせず、影の見た目もこちらで制御できる。
enum ShadowCompositor {

    /// 影のパラメータ。macOS のウィンドウ影に寄せた値。
    ///
    /// 本物の影と完全に同一にはならないが、資料やブログに貼る用途では
    /// 十分に自然に見える。数値はポイント基準で持ち、実際の描画時に
    /// 画像の倍率を掛ける（Retina で影だけ相対的に細くならないように）。
    ///
    /// 角丸半径をここに持たないのは意図的。影の形は画像自身のアルファから
    /// 作るため、半径を知る必要がない（下記の描画部分を参照）。
    private enum Shadow {
        /// ぼかし半径。
        static let blurRadius: CGFloat = 24
        /// 下方向へのずれ。macOS の影はわずかに下に落ちる。
        static let offsetY: CGFloat = 10
        /// 影の濃さ。
        static let alpha: CGFloat = 0.38
        /// 画像の外側に確保する余白。
        ///
        /// ぼかし半径だけでは足りない（ガウシアンの裾が切れて影が
        /// 直線的に途切れる）。半径の 2 倍強を目安にし、下方向は
        /// ずれの分を足す。
        static let margin: CGFloat = blurRadius * 2 + 8
    }

    /// 画像の周囲に余白を足し、ドロップシャドウを描いて元画像を重ねる。
    /// - Parameters:
    ///   - image: 影なしで撮ったウィンドウ画像。
    ///   - scale: 画像の倍率（Retina なら 2.0）。影の寸法をこれに合わせる。
    /// - Returns: 影付きの画像。合成に失敗した場合は元画像をそのまま返す
    ///   （影が付かないだけで、キャプチャ自体は成立させる）。
    static func addShadow(to image: CGImage, scale: CGFloat) -> CGImage {
        let margin = (Shadow.margin * scale).rounded()
        let offsetY = (Shadow.offsetY * scale).rounded()
        let blur = Shadow.blurRadius * scale

        // 下方向にずれる分だけ、下の余白を厚くする。
        // 上下同じ余白だと影が下端で切れる。
        let width = image.width + Int(margin * 2)
        let height = image.height + Int(margin * 2 + offsetY)
        guard width > 0, height > 0 else { return image }

        // 透明背景を保つため RGBA。貼り付け先が白でも黒でも馴染む。
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // 元画像を置く位置。CGContext は左下原点なので、下の余白が
        // 厚いぶん上に寄せる（= margin + offsetY を下に取る）。
        let imageRect = CGRect(
            x: margin,
            y: margin + offsetY,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )

        // 影を描く。
        //
        // ★影を落とす形は「画像自身のアルファ」から作る。
        //
        // ScreenCaptureKit が返す画像は矩形だが、**ウィンドウの角丸は
        // アルファとして正しく入っている**（実測: 半径 15px の輪郭が
        // アルファに現れる）。`CGContext.setShadow` は描いたものの形に
        // 影を落とすので、画像をそのまま描けば角丸に沿った正確な影になる。
        //
        // 角丸半径をハードコードして矩形を塗る方式は誤りだった。半径が
        // 実際（15px）より小さいと、その差分の角が白い三角として残る。
        // 半径はアプリや macOS のバージョンで変わるため、推測してはいけない。
        //
        // 影の Y オフセットは負にする。CGContext の Y は上向きなので、
        // 画面上で下に落とすには負の値を指定する。
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -offsetY),
            blur: blur,
            color: NSColor.black.withAlphaComponent(Shadow.alpha).cgColor
        )
        context.interpolationQuality = .none
        context.draw(image, in: imageRect)
        context.restoreGState()

        // 本体をもう一度、影なしで上書きする。
        //
        // 1 回目の描画は影を出すためのもので、半透明なウィンドウでは
        // その下に敷かれた影が透けて中身が暗く見える。同じ位置に
        // 影なしで重ねれば、見えるのは本来の色になる。
        //
        // imageRect は元画像と同じピクセル数なので、リサンプリングは
        // 起きない。それでも補間設定を明示するのは、将来この位置に
        // 小数が入り込んだときに黙ってぼやけないようにするため。
        context.interpolationQuality = .none
        context.draw(image, in: imageRect)

        return context.makeImage() ?? image
    }
}
