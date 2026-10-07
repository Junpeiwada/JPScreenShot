import AppKit
import CoreGraphics
import CoreText

// 注釈を CGContext に描く。画面表示とコピー・保存の書き出しは必ずここを通す
// （画面と出力で見た目がずれないようにするため）。
//
// ★描画先の前提: **ポイント座標・y 下向きの CGContext**。
// 画面（flipped な NSView）ではそのまま使える。書き出し用のビットマップ
// コンテキストは左下原点なので、`renderFlattened` が自分で flip と scale を設定する。
// この関数群を別のコンテキストで使うときは、同じ座標系に整えてから呼ぶこと。
//
// ★影について: `CGContext.setShadow` のオフセットとぼかし半径は **CTM の影響を受けず
// デバイス（出力ピクセル）単位・y 上向き** で解釈される（実測）。そのため、
// ポイントで持つ値に CTM の倍率を掛けて渡し、「下へ distance」は負の y にする。
@MainActor
enum AnnotationRenderer {

    // MARK: 書き出し

    /// 元画像に注釈を焼き込んだ画像を返す。ピクセル寸法は元画像と同じ。
    /// 元画像が HDR（16bit float・拡張 sRGB）なら出力も 16bit float・拡張 sRGB で、1.0 超を保つ。
    ///
    /// - Parameters:
    ///   - base: 元画像。
    ///   - scale: 1 ポイントあたりのピクセル数（`CaptureResult.scale`）。
    ///   - annotations: 注釈（配列順＝重なり順。層はこの関数が分ける）。
    /// - Returns: 注釈が 0 件なら元画像そのもの（画素を一切変えない）。作れなければ nil。
    static func renderFlattened(base: CGImage, scale: CGFloat, annotations: [Annotation]) -> CGImage? {
        guard !annotations.isEmpty else { return base }
        let scale = scale > 0 ? scale : 1

        // ★合成先の形式は元画像に合わせる（ShadowCompositor と同じ流儀）。
        // HDR 版（拡張 sRGB・16bit float）を 8bit に描くと 1.0 超の明部が 1.0 に潰れる。
        // HDR のときだけ拡張 sRGB の 16bit float で合成し、SDR は従来どおり 8bit・元の色空間。
        // 注釈の色（NSColor → CGColor）は SDR の 0…1 の値のまま描く。拡張 sRGB に sRGB の色を
        // 描いても値は 1.0 以下に収まるので、注釈の白は 1.0 のまま HDR の明部のようには光らない。
        let hdr = HDRPixelFormat.isHDR(base)
        let sdrColorSpace = HDRPixelFormat.sdrColorSpace(for: base)
        guard
            let context = HDRPixelFormat.makeContext(
                width: base.width, height: base.height, hdr: hdr, sdrColorSpace: sdrColorSpace)
        else { return nil }

        // 元画像はピクセル等倍で補間なしに置く（ぼやけと画素のずれを避ける）。
        context.interpolationQuality = .none
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        // ここから「ポイント座標・y 下向き」。
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high

        let redaction = RedactionRenderer(base: base, scale: scale)
        draw(annotations, using: redaction, in: context, exporting: true)
        return context.makeImage()
    }

    // MARK: 層ごとの描画

    /// 範囲加工層と図形層を、この順に描く。元画像は呼び出し側が先に描いておく。
    /// - Parameters:
    ///   - hiding: 描かない注釈（テキスト編集中、その注釈を隠すのに使う）。
    ///   - exporting: 書き出し用。加工部分の画像は画素どうしが 1:1 で重なるので補間しない。
    ///     画面表示（縮小・拡大あり）では高品質で補間する。
    static func draw(
        _ annotations: [Annotation],
        using redaction: RedactionRenderer,
        in context: CGContext,
        hiding: Set<UUID> = [],
        exporting: Bool = false
    ) {
        drawRedactions(
            annotations, using: redaction, in: context, hiding: hiding, exporting: exporting)
        drawFigures(annotations, in: context, hiding: hiding)
    }

    /// ぼかし・モザイク層。
    static func drawRedactions(
        _ annotations: [Annotation],
        using redaction: RedactionRenderer,
        in context: CGContext,
        hiding: Set<UUID> = [],
        exporting: Bool = false
    ) {
        for annotation in annotations
        where annotation.layer == .redaction && !hiding.contains(annotation.id) {
            guard let piece = redaction.piece(for: annotation) else { continue }
            drawImage(piece.image, in: piece.rect, context: context, exporting: exporting)
        }
    }

    /// 図形・テキスト層。
    static func drawFigures(
        _ annotations: [Annotation],
        in context: CGContext,
        hiding: Set<UUID> = []
    ) {
        for annotation in annotations
        where annotation.layer == .figure && !hiding.contains(annotation.id) {
            draw(figure: annotation, in: context)
        }
    }

    /// 図形・テキスト 1 件。
    static func draw(figure annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        // 影は塗りと線とを別々に落とすと重なって濃くなるので、透明レイヤーに
        // まとめて描き、全体に 1 回だけ影を落とす。
        let shadow = annotation.style.shadow
        if shadow.isOn {
            // CTM の拡大率（ポイント→デバイスピクセル）。影は CTM を受けないので自分で掛ける。
            let ctm = context.ctm
            let factor = hypot(ctm.a, ctm.b)
            context.setShadow(
                offset: CGSize(width: 0, height: -CGFloat(shadow.distance) * factor),
                blur: CGFloat(shadow.blur) * factor,
                color: CGColor(gray: 0, alpha: 0.5))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        switch annotation.kind {
        case .arrow, .line: drawLinear(annotation, in: context)
        case .rect, .ellipse: drawBoxed(annotation, in: context)
        case .text: drawText(annotation, in: context)
        case .blur, .mosaic: break  // 範囲加工層で描く
        }

        if shadow.isOn { context.endTransparencyLayer() }
    }

    // MARK: 線・矢印

    /// 矢印の頭の長さ（線の太さに比例。細い線でも見えるよう下限を置く）。
    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat { max(lineWidth * 4.5, 10) }

    /// 矢印の頭の幅（底辺の全幅）。
    static func arrowHeadWidth(lineWidth: CGFloat) -> CGFloat { max(lineWidth * 3.6, 8) }

    private static func drawLinear(_ annotation: Annotation, in context: CGContext) {
        let style = annotation.style
        let width = CGFloat(style.lineWidth)
        let color = style.color.cgColor
        let start = annotation.start
        let end = annotation.end
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }

        let heads: ArrowHeads = annotation.kind == .arrow ? style.arrowHeads : .none
        let ux = (end.x - start.x) / length
        let uy = (end.y - start.y) / length

        // 頭の大きさは線の長さを超えない（短い矢印で頭がはみ出さないように）。
        let headLength = min(arrowHeadLength(lineWidth: width), length / (heads == .both ? 2 : 1))
        let headWidth = arrowHeadWidth(lineWidth: width) * headLength / arrowHeadLength(lineWidth: width)

        // 軸は頭の底辺までで止める（先の尖りから軸が飛び出さないように）。
        // 少し食い込ませて、頭との間に隙間が出ないようにする。
        let overlap = headLength * 0.1
        var shaftStart = start
        var shaftEnd = end
        if heads == .both {
            shaftStart = CGPoint(x: start.x + ux * (headLength - overlap), y: start.y + uy * (headLength - overlap))
        }
        if heads != .none {
            shaftEnd = CGPoint(x: end.x - ux * (headLength - overlap), y: end.y - uy * (headLength - overlap))
        }

        context.setStrokeColor(color)
        context.setLineWidth(width)
        applyDash(style.dash, width: width, to: context)
        context.move(to: shaftStart)
        context.addLine(to: shaftEnd)
        context.strokePath()

        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(color)
        if heads != .none {
            fillHead(tip: end, direction: CGPoint(x: ux, y: uy), length: headLength, width: headWidth, in: context)
        }
        if heads == .both {
            fillHead(tip: start, direction: CGPoint(x: -ux, y: -uy), length: headLength, width: headWidth, in: context)
        }
    }

    /// 塗りつぶした三角の頭。`direction` は軸の進行方向（先端が向く側）。
    private static func fillHead(
        tip: CGPoint, direction: CGPoint, length: CGFloat, width: CGFloat, in context: CGContext
    ) {
        let baseCenter = CGPoint(x: tip.x - direction.x * length, y: tip.y - direction.y * length)
        // 進行方向に直交する向き。
        let nx = -direction.y
        let ny = direction.x
        context.move(to: tip)
        context.addLine(to: CGPoint(x: baseCenter.x + nx * width / 2, y: baseCenter.y + ny * width / 2))
        context.addLine(to: CGPoint(x: baseCenter.x - nx * width / 2, y: baseCenter.y - ny * width / 2))
        context.closePath()
        context.fillPath()
    }

    private static func applyDash(_ dash: LineDash, width: CGFloat, to context: CGContext) {
        switch dash {
        case .solid:
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [])
        case .dashed:
            // 破線は丸い端だと点線のようにつながって見えるので、平らな端にする。
            context.setLineCap(.butt)
            context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
        }
    }

    // MARK: 四角・円

    private static func drawBoxed(_ annotation: Annotation, in context: CGContext) {
        let style = annotation.style
        let rect = AnnotationGeometry.bounds(of: annotation)
        guard rect.width > 0 || rect.height > 0 else { return }

        func addPath() {
            if annotation.kind == .ellipse {
                context.addEllipse(in: rect)
            } else {
                context.addRect(rect)
            }
        }

        switch style.fill {
        case .none:
            break
        case .translucent:
            context.setFillColor(style.color.withAlpha(style.color.alpha * 0.3).cgColor)
            addPath()
            context.fillPath()
        case .solid:
            context.setFillColor(style.color.cgColor)
            addPath()
            context.fillPath()
        }

        let width = CGFloat(style.lineWidth)
        guard width > 0 else { return }
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.miter)
        applyDash(style.dash, width: width, to: context)
        addPath()
        context.strokePath()
    }

    // MARK: テキスト

    private static func drawText(_ annotation: Annotation, in context: CGContext) {
        AnnotationTextLayout.draw(
            annotation.text, style: annotation.style.text, origin: annotation.start, in: context)
    }

    // MARK: 画像

    /// y 下向きのコンテキストに CGImage を正立で描く（そのまま draw すると上下が逆になる）。
    private static func drawImage(
        _ image: CGImage, in rect: CGRect, context: CGContext, exporting: Bool
    ) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = exporting ? .none : .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}

// MARK: - テキストのレイアウト

/// テキストの測定と描画（CoreText）。
///
/// 外接矩形の計算と描画で**同じ行メトリクス**を使う。ジオメトリ（選択枠・当たり判定）と
/// レンダラが別々に計算すると、選択枠が文字からずれる。
/// 状態を持たない純粋な処理なのでアクター隔離しない。
enum AnnotationTextLayout {

    /// 1 行ぶんの測定結果。
    private struct Line {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let height: CGFloat
    }

    /// スタイルから作ったフォント。名前が見つからなければシステムフォント。
    static func font(for style: TextStyle) -> CTFont {
        let size = CGFloat(max(style.size, 1))
        let weight = NSFont.Weight(rawValue: style.weight.traitValue)
        // PostScript 名で引く。保存値がファミリー名でも引けるよう、失敗したら
        // ファミリー指定で引き直す（一覧は PostScript 名を入れるが、古い値への保険）。
        let named: NSFont? =
            style.fontName.isEmpty
            ? nil
            : NSFont(name: style.fontName, size: size)
                ?? NSFont(
                    descriptor: NSFontDescriptor(fontAttributes: [.family: style.fontName]),
                    size: size
                ).flatMap { $0.familyName == style.fontName ? $0 : nil }
        guard let named else {
            return NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        }
        // ウエイトはファミリー指定＋ウエイトのトレイトで引く。名前（PostScript 名）の
        // ままトレイトだけ足しても、複数の太さを持つフォントでは効かないことがある。
        // 見つからなければ（太さが 1 種類しかないフォントなど）名前で引いたものを使う。
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: named.familyName ?? style.fontName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return (NSFont(descriptor: descriptor, size: size) ?? named) as CTFont
    }

    /// 文字列の外接矩形の大きさ（複数行対応）。縁取りの張り出しは含まない。
    static func size(of text: String, style: TextStyle) -> CGSize {
        let lines = layout(text, font: font(for: style))
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /// `origin`（外接矩形の左上）に文字列を描く。コンテキストは y 下向きの前提。
    ///
    /// 縁取りは**縁を先に stroke してから、その上に fill**する。fill を先にすると、
    /// 縁の線が文字の内側へ食い込んで文字が痩せて見える。縁の線幅は
    /// 「縁の太さ × 2」（線は輪郭の内外へ半分ずつ出るので、外側へ張り出す幅が
    /// 縁の太さになる）。角は丸め、細かい文字の尖りが出ないようにする。
    static func draw(_ text: String, style: TextStyle, origin: CGPoint, in context: CGContext) {
        let lines = layout(text, font: font(for: style))
        guard !lines.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // CoreText は y 上向き前提で描くので、y 下向きのコンテキストでは文字ごと
        // 反転する。textMatrix で反転し、ベースラインの位置を y 下向きで指定する。
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // 縁は**全行を先に**描き、そのあとで全行の文字を塗る。行ごとに縁→文字と
        // 進めると、次の行の縁が前の行の文字（g・y の下端など）に被って削ってしまう。
        func baselines() -> [CGFloat] {
            var top = origin.y
            return lines.map { line in
                defer { top += line.height }
                return top + line.ascent
            }
        }
        let positions = baselines()

        if style.outline.isOn, style.outline.width > 0 {
            context.setTextDrawingMode(.stroke)
            context.setStrokeColor(style.outline.color.cgColor)
            context.setLineWidth(CGFloat(style.outline.width) * 2)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            for (line, baseline) in zip(lines, positions) {
                context.textPosition = CGPoint(x: origin.x, y: baseline)
                CTLineDraw(line.line, context)
            }
        }
        context.setTextDrawingMode(.fill)
        context.setFillColor(style.color.cgColor)
        for (line, baseline) in zip(lines, positions) {
            context.textPosition = CGPoint(x: origin.x, y: baseline)
            CTLineDraw(line.line, context)
        }
    }

    /// 行ごとに CTLine を作って測る。行の高さは、フォントの標準値と
    /// 実際の行（フォールバックした日本語フォントなど）の大きい方を使う。
    private static func layout(_ text: String, font: CTFont) -> [Line] {
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontLeading = CTFontGetLeading(font)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // 色は CGContext の fill / stroke の色を使う（縁取りと文字で色を変えるため）。
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return text.components(separatedBy: "\n").map { string in
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: attributes))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let a = max(ascent, fontAscent)
            let d = max(descent, fontDescent)
            let l = max(leading, fontLeading)
            return Line(line: line, width: string.isEmpty ? 0 : width, ascent: a, height: a + d + l)
        }
    }
}
