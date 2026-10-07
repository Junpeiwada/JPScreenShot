import CoreGraphics
import Foundation

// 注釈の幾何（当たり判定・ハンドル・移動・変形・Shift 拘束・正規化）。
//
// すべて副作用のない純粋関数で、画面にも権限にも依存しない（テストしやすい）。
// 座標は画像のポイント座標（左上原点・y 下向き）。
//
// 「許容幅」（tolerance）はいずれも**ポイント換算**で呼び出し側が渡す。
// ハンドルのつかみやすさや線のクリックしやすさは画面上の大きさで一定に
// したいので、縮小表示中は「画面上 N px ÷ 表示倍率」を渡す想定
// （等倍なら N、50% 表示なら 2N）。ここでは表示倍率を知らない。
enum AnnotationGeometry {

    // MARK: ハンドル

    /// 変形用のハンドル。
    ///
    /// 矩形系（四角・円・ぼかし・モザイク・テキスト）は外接矩形の 8 点、
    /// 線・矢印は両端の 2 点（start / end）。
    enum Handle: Sendable, Hashable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case start, end
    }

    /// ハンドルとその位置の組。
    struct HandlePosition: Sendable, Hashable {
        let handle: Handle
        let point: CGPoint
    }

    // MARK: 外接矩形

    /// 2 点から作る矩形。負の幅・高さは出ない（どの対角でもよい）。
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    /// 注釈の外接矩形（線の太さは含まない）。選択枠・ハンドル・ぼかし範囲に使う。
    ///
    /// テキストは文字列から計算する。レンダラと同じ値を使うので、
    /// 選択枠と実際の描画範囲がずれない。
    static func bounds(of annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .text:
            let size = AnnotationTextLayout.size(of: annotation.text, style: annotation.style.text)
            return CGRect(origin: annotation.start, size: size)
        default:
            return rect(from: annotation.start, to: annotation.end)
        }
    }

    /// 始点・終点を矩形の左上・右下に揃えた注釈を返す（負の幅を直す）。
    ///
    /// 矩形系だけが対象。線・矢印は向きに意味があるので変えない。
    /// テキストは `end` を使わないのでそのまま。
    static func normalized(_ annotation: Annotation) -> Annotation {
        guard annotation.kind.isBoxed else { return annotation }
        var result = annotation
        let r = rect(from: annotation.start, to: annotation.end)
        result.start = CGPoint(x: r.minX, y: r.minY)
        result.end = CGPoint(x: r.maxX, y: r.maxY)
        return result
    }

    // MARK: 当たり判定

    /// 点が注釈に当たっているか。
    ///
    /// - 線・矢印: 線分との距離が「太さの半分＋許容幅」以内
    /// - 四角・円: 枠線の付近。塗りがあれば内部も
    /// - テキスト: 外接矩形（許容幅ぶん広げる）
    /// - ぼかし・モザイク: 内部（形が楕円なら楕円の内部）
    static func hitTest(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        let half = CGFloat(annotation.style.lineWidth) / 2
        switch annotation.kind {
        case .arrow, .line:
            return distance(from: point, toSegment: annotation.start, annotation.end)
                <= half + tolerance

        case .rect:
            let b = bounds(of: annotation)
            let margin = half + tolerance
            guard b.insetBy(dx: -margin, dy: -margin).contains(point) else { return false }
            if annotation.style.fill != .none { return true }
            // 内側の矩形に入っていなければ枠線付近。内側が潰れる小さい矩形は
            // 全体が枠線の範囲なので当たりとする。
            let inner = b.insetBy(dx: margin, dy: margin)
            return inner.width <= 0 || inner.height <= 0 || !inner.contains(point)

        case .ellipse:
            let b = bounds(of: annotation)
            let margin = half + tolerance
            guard ellipseContains(b, expandedBy: margin, point) else { return false }
            if annotation.style.fill != .none { return true }
            let innerA = b.width / 2 - margin
            let innerB = b.height / 2 - margin
            if innerA <= 0 || innerB <= 0 { return true }
            return !ellipseContains(b, expandedBy: -margin, point)

        case .text:
            return bounds(of: annotation)
                .insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .blur, .mosaic:
            let b = bounds(of: annotation)
            if annotation.style.redaction.shape == .ellipse {
                return ellipseContains(b, expandedBy: tolerance, point)
            }
            return b.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// 点と線分の距離。
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        // 始点と終点が同じ（長さ 0）なら点との距離。
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 矩形に内接する楕円を `expandedBy` だけ広げた（負なら狭めた）楕円が点を含むか。
    private static func ellipseContains(_ rect: CGRect, expandedBy margin: CGFloat, _ p: CGPoint) -> Bool {
        let a = rect.width / 2 + margin
        let b = rect.height / 2 + margin
        guard a > 0, b > 0 else { return false }
        let dx = (p.x - rect.midX) / a
        let dy = (p.y - rect.midY) / b
        return dx * dx + dy * dy <= 1
    }

    // MARK: ハンドル位置

    /// 選択中に表示するハンドルの位置。
    static func handles(of annotation: Annotation) -> [HandlePosition] {
        if annotation.kind.isLinear {
            return [
                HandlePosition(handle: .start, point: annotation.start),
                HandlePosition(handle: .end, point: annotation.end),
            ]
        }
        let b = bounds(of: annotation)
        return [
            HandlePosition(handle: .topLeft, point: CGPoint(x: b.minX, y: b.minY)),
            HandlePosition(handle: .topRight, point: CGPoint(x: b.maxX, y: b.minY)),
            HandlePosition(handle: .bottomRight, point: CGPoint(x: b.maxX, y: b.maxY)),
            HandlePosition(handle: .bottomLeft, point: CGPoint(x: b.minX, y: b.maxY)),
            HandlePosition(handle: .top, point: CGPoint(x: b.midX, y: b.minY)),
            HandlePosition(handle: .right, point: CGPoint(x: b.maxX, y: b.midY)),
            HandlePosition(handle: .bottom, point: CGPoint(x: b.midX, y: b.maxY)),
            HandlePosition(handle: .left, point: CGPoint(x: b.minX, y: b.midY)),
        ]
    }

    /// 点の位置にあるハンドル。許容幅（ポイント換算）以内で最も近いもの。
    ///
    /// 小さな矩形では 8 点が重なるので、距離が最小のものを返す
    /// （同距離なら角が先＝`handles(of:)` の並び順）。
    static func handle(at point: CGPoint, of annotation: Annotation, tolerance: CGFloat) -> Handle? {
        var best: (handle: Handle, distance: CGFloat)?
        for position in handles(of: annotation) {
            let d = hypot(point.x - position.point.x, point.y - position.point.y)
            guard d <= tolerance else { continue }
            if best == nil || d < best!.distance { best = (position.handle, d) }
        }
        return best?.handle
    }

    // MARK: 移動・変形

    /// 注釈を平行移動する。
    static func moved(_ annotation: Annotation, by delta: CGSize) -> Annotation {
        var result = annotation
        result.start = CGPoint(x: annotation.start.x + delta.width, y: annotation.start.y + delta.height)
        result.end = CGPoint(x: annotation.end.x + delta.width, y: annotation.end.y + delta.height)
        return result
    }

    /// ハンドルをドラッグして形を変えた注釈を返す。
    ///
    /// **ドラッグ開始時の注釈（original）と現在のマウス位置から毎回計算する**
    /// 状態を持たない関数。反対側の辺を越えて引っ張っても、その都度
    /// 矩形が作り直されるので自然に反転する（ハンドルの意味を覚えておく必要がない）。
    ///
    /// - Parameters:
    ///   - constrain: Shift 拘束。矩形系は正方形・正円、線・矢印は 45° 刻み、
    ///     テキストは縦横比の維持（常に維持なので影響なし）。
    static func resized(
        _ original: Annotation,
        handle: Handle,
        to point: CGPoint,
        constrain: Bool = false
    ) -> Annotation {
        var result = original

        // 線・矢印: 動かす端だけ変え、反対の端を基準に拘束する。
        if original.kind.isLinear {
            switch handle {
            case .start:
                result.start = constrain
                    ? constrained(anchor: original.end, point: point, kind: original.kind) : point
            case .end:
                result.end = constrain
                    ? constrained(anchor: original.start, point: point, kind: original.kind) : point
            default:
                break
            }
            return result
        }

        if original.kind == .text {
            return resizedText(original, handle: handle, to: point)
        }

        // 矩形系: 正規化してから、ハンドルに応じて動かす辺を決める。
        let b = bounds(of: original)
        // 固定される側の座標（動かさない辺・角）。
        var anchorX: CGFloat? = nil
        var anchorY: CGFloat? = nil
        var moveX = true
        var moveY = true
        switch handle {
        case .topLeft: anchorX = b.maxX; anchorY = b.maxY
        case .topRight: anchorX = b.minX; anchorY = b.maxY
        case .bottomLeft: anchorX = b.maxX; anchorY = b.minY
        case .bottomRight: anchorX = b.minX; anchorY = b.minY
        case .top: anchorY = b.maxY; moveX = false
        case .bottom: anchorY = b.minY; moveX = false
        case .left: anchorX = b.maxX; moveY = false
        case .right: anchorX = b.minX; moveY = false
        case .start, .end: return original
        }

        var p = point
        if constrain, moveX, moveY, let ax = anchorX, let ay = anchorY {
            // 角ハンドルだけ正方形に拘束する（辺ハンドルは 1 方向しか動かさない）。
            p = constrained(anchor: CGPoint(x: ax, y: ay), point: point, kind: original.kind)
        }

        let x1 = moveX ? (anchorX ?? b.minX) : b.minX
        let x2 = moveX ? p.x : b.maxX
        let y1 = moveY ? (anchorY ?? b.minY) : b.minY
        let y2 = moveY ? p.y : b.maxY
        let r = rect(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
        result.start = CGPoint(x: r.minX, y: r.minY)
        result.end = CGPoint(x: r.maxX, y: r.maxY)
        return result
    }

    /// テキストの変形。枠の大きさに応じて**文字サイズを比例させる**
    /// （枠での折り返しはしない）。反対側の角・辺を固定する。
    private static func resizedText(_ original: Annotation, handle: Handle, to point: CGPoint) -> Annotation {
        let b = bounds(of: original)
        guard b.width > 0, b.height > 0 else { return original }

        // 比率はドラッグしたハンドルの方向で決める。角は縦横の大きい方。
        let ratio: CGFloat
        switch handle {
        case .left: ratio = (b.maxX - point.x) / b.width
        case .right: ratio = (point.x - b.minX) / b.width
        case .top: ratio = (b.maxY - point.y) / b.height
        case .bottom: ratio = (point.y - b.minY) / b.height
        case .topLeft: ratio = max((b.maxX - point.x) / b.width, (b.maxY - point.y) / b.height)
        case .topRight: ratio = max((point.x - b.minX) / b.width, (b.maxY - point.y) / b.height)
        case .bottomLeft: ratio = max((b.maxX - point.x) / b.width, (point.y - b.minY) / b.height)
        case .bottomRight: ratio = max((point.x - b.minX) / b.width, (point.y - b.minY) / b.height)
        case .start, .end: return original
        }

        var result = original
        let minimumSize = 4.0
        result.style.text.size = max(minimumSize, original.style.text.size * Double(max(ratio, 0)))
        let newSize = AnnotationTextLayout.size(of: result.text, style: result.style.text)

        // 固定する側（ドラッグしたハンドルの反対）に外接矩形を寄せる。
        let originX: CGFloat
        switch handle {
        case .left, .topLeft, .bottomLeft: originX = b.maxX - newSize.width
        case .right, .topRight, .bottomRight: originX = b.minX
        default: originX = b.midX - newSize.width / 2
        }
        let originY: CGFloat
        switch handle {
        case .top, .topLeft, .topRight: originY = b.maxY - newSize.height
        case .bottom, .bottomLeft, .bottomRight: originY = b.minY
        default: originY = b.midY - newSize.height / 2
        }
        result.start = CGPoint(x: originX, y: originY)
        result.end = result.start
        return result
    }

    // MARK: Shift 拘束

    /// Shift を押しているときの終点。
    ///
    /// - 線・矢印: 基準点からの角度を 45° 刻みに丸める（長さは保つ）
    /// - 矩形系: 縦横の大きい方に揃えた正方形（向きの符号は保つ）。
    ///   楕円なら正円、ぼかし・モザイクなら正方形/正円になる
    static func constrained(anchor: CGPoint, point: CGPoint, kind: AnnotationKind) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        if kind.isLinear {
            let length = hypot(dx, dy)
            guard length > 0 else { return point }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle))
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(
            x: anchor.x + (dx < 0 ? -side : side),
            y: anchor.y + (dy < 0 ? -side : side)
        )
    }
}
