import CoreGraphics
import Testing

@testable import JPScreenShot

// 注釈の幾何は座標計算だけの純粋関数。画面にも権限にも依存しない。
// 許容幅（tolerance）はポイント換算で渡す設計なので、テストでも明示的に渡す。
@Suite("注釈のジオメトリ")
struct AnnotationGeometryTests {

    private func shape(
        _ kind: AnnotationKind,
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: Double = 4,
        fill: FillMode = .none
    ) -> Annotation {
        var style = AnnotationStyle()
        style.lineWidth = lineWidth
        style.fill = fill
        return Annotation(kind: kind, start: start, end: end, style: style)
    }

    private func close(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.001) -> Bool {
        abs(a - b) < eps
    }

    // MARK: 当たり判定

    @Test("線は太さの半分＋許容幅の内側だけ当たる")
    func 線の当たり判定() {
        let line = shape(.line, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 4)
        // 太さ 4 → 半分の 2 ＋ 許容 3 = 5 まで当たる。
        #expect(AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 4.9), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 5.1), tolerance: 3))
        // 端点の外側は端点からの距離で判定する。
        #expect(AnnotationGeometry.hitTest(line, at: CGPoint(x: 104, y: 0), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(line, at: CGPoint(x: 106, y: 0), tolerance: 3))
    }

    @Test("長さ 0 の線でも点との距離で判定できる")
    func 長さ0の線() {
        let line = shape(.arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10))
        #expect(AnnotationGeometry.hitTest(line, at: CGPoint(x: 11, y: 10), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(line, at: CGPoint(x: 30, y: 10), tolerance: 3))
    }

    @Test("塗りなしの四角は枠線付近だけ、塗りありなら内部も当たる")
    func 四角の当たり判定() {
        let hollow = shape(.rect, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        #expect(AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 0, y: 50), tolerance: 3))
        #expect(AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 103, y: 50), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 50, y: 50), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 120, y: 50), tolerance: 3))

        let filled = shape(.rect, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), fill: .translucent)
        #expect(AnnotationGeometry.hitTest(filled, at: CGPoint(x: 50, y: 50), tolerance: 3))
    }

    @Test("始点・終点がどの対角でも四角は同じ判定になる")
    func 四角の逆向き() {
        let reversed = shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 0, y: 0), fill: .solid)
        #expect(AnnotationGeometry.hitTest(reversed, at: CGPoint(x: 50, y: 50), tolerance: 3))
    }

    @Test("円は枠線付近と、塗りがあれば内部に当たる")
    func 円の当たり判定() {
        let hollow = shape(.ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        // 円周上の点（中心 (50,50)、半径 50）。
        #expect(AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 100, y: 50), tolerance: 3))
        #expect(AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 50, y: 0), tolerance: 3))
        // 外接矩形の角は円の外側。
        #expect(!AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 2, y: 2), tolerance: 3))
        // 内部（塗りなし）は当たらない。
        #expect(!AnnotationGeometry.hitTest(hollow, at: CGPoint(x: 50, y: 50), tolerance: 3))

        let filled = shape(.ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), fill: .solid)
        #expect(AnnotationGeometry.hitTest(filled, at: CGPoint(x: 50, y: 50), tolerance: 3))
        #expect(!AnnotationGeometry.hitTest(filled, at: CGPoint(x: 2, y: 2), tolerance: 3))
    }

    @Test("ぼかし・モザイクは内部が当たる。楕円形なら角は外れる")
    func 範囲加工の当たり判定() {
        var blur = shape(.blur, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        #expect(AnnotationGeometry.hitTest(blur, at: CGPoint(x: 50, y: 50), tolerance: 0))
        #expect(AnnotationGeometry.hitTest(blur, at: CGPoint(x: 2, y: 2), tolerance: 0))
        #expect(!AnnotationGeometry.hitTest(blur, at: CGPoint(x: 120, y: 50), tolerance: 0))

        blur.style.redaction.shape = .ellipse
        #expect(AnnotationGeometry.hitTest(blur, at: CGPoint(x: 50, y: 50), tolerance: 0))
        #expect(!AnnotationGeometry.hitTest(blur, at: CGPoint(x: 2, y: 2), tolerance: 0))
    }

    @Test("テキストは外接矩形（許容幅つき）に当たる")
    func テキストの当たり判定() {
        let text = Annotation(kind: .text, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 20, y: 30), text: "Hello")
        let bounds = AnnotationGeometry.bounds(of: text)
        #expect(bounds.width > 0 && bounds.height > 0)
        #expect(AnnotationGeometry.hitTest(text, at: CGPoint(x: bounds.midX, y: bounds.midY), tolerance: 0))
        #expect(!AnnotationGeometry.hitTest(text, at: CGPoint(x: bounds.maxX + 10, y: bounds.midY), tolerance: 3))
    }

    // MARK: ハンドル

    @Test("矩形系は 8 点、線・矢印は両端の 2 点のハンドルを持つ")
    func ハンドルの数と位置() {
        let rect = shape(.rect, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70))
        let handles = AnnotationGeometry.handles(of: rect)
        #expect(handles.count == 8)
        let byHandle = Dictionary(uniqueKeysWithValues: handles.map { ($0.handle, $0.point) })
        #expect(byHandle[.topLeft] == CGPoint(x: 10, y: 20))
        #expect(byHandle[.bottomRight] == CGPoint(x: 110, y: 70))
        #expect(byHandle[.top] == CGPoint(x: 60, y: 20))
        #expect(byHandle[.left] == CGPoint(x: 10, y: 45))

        let arrow = shape(.arrow, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 60))
        let arrowHandles = AnnotationGeometry.handles(of: arrow)
        #expect(arrowHandles.map(\.handle) == [.start, .end])
        #expect(arrowHandles.map(\.point) == [CGPoint(x: 5, y: 5), CGPoint(x: 50, y: 60)])
    }

    @Test("許容幅の内側のハンドルを拾い、外側では nil")
    func ハンドルの当たり() {
        let rect = shape(.rect, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 101, y: 1), of: rect, tolerance: 4) == .topRight)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 50, y: 99), of: rect, tolerance: 4) == .bottom)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 50, y: 50), of: rect, tolerance: 4) == nil)
        // 許容幅を広げるとつかめる（縮小表示では広い許容幅が渡される）。
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 50, y: 92), of: rect, tolerance: 10) == .bottom)
    }

    // MARK: 移動・変形

    @Test("移動は始点・終点を同じだけずらす")
    func 移動() {
        let line = shape(.line, from: CGPoint(x: 1, y: 2), to: CGPoint(x: 11, y: 12))
        let moved = AnnotationGeometry.moved(line, by: CGSize(width: 5, height: -3))
        #expect(moved.start == CGPoint(x: 6, y: -1))
        #expect(moved.end == CGPoint(x: 16, y: 9))
    }

    @Test("角ハンドルで反対の角を固定したまま変形できる")
    func 角ハンドルの変形() {
        let rect = shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        let resized = AnnotationGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 150, y: 90))
        #expect(resized.start == CGPoint(x: 10, y: 10))
        #expect(resized.end == CGPoint(x: 150, y: 90))

        let fromTopLeft = AnnotationGeometry.resized(rect, handle: .topLeft, to: CGPoint(x: 0, y: 0))
        #expect(fromTopLeft.start == CGPoint(x: 0, y: 0))
        #expect(fromTopLeft.end == CGPoint(x: 110, y: 60))
    }

    @Test("辺ハンドルは 1 方向だけ動く")
    func 辺ハンドルの変形() {
        let rect = shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        let resized = AnnotationGeometry.resized(rect, handle: .right, to: CGPoint(x: 200, y: 999))
        #expect(resized.start == CGPoint(x: 10, y: 10))
        #expect(resized.end == CGPoint(x: 200, y: 60))
    }

    @Test("反対側の辺を越えて引くと反転し、負の幅にならない")
    func 反転() {
        let rect = shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        let resized = AnnotationGeometry.resized(rect, handle: .right, to: CGPoint(x: -20, y: 0))
        #expect(resized.start.x == -20)
        #expect(resized.end.x == 10)
        #expect(resized.end.x >= resized.start.x)
        #expect(resized.end.y >= resized.start.y)
    }

    @Test("線・矢印は端のハンドルで向きと長さを変える")
    func 線の変形() {
        let arrow = shape(.arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        let movedEnd = AnnotationGeometry.resized(arrow, handle: .end, to: CGPoint(x: 30, y: 40))
        #expect(movedEnd.start == CGPoint(x: 0, y: 0))
        #expect(movedEnd.end == CGPoint(x: 30, y: 40))
        let movedStart = AnnotationGeometry.resized(arrow, handle: .start, to: CGPoint(x: -5, y: 7))
        #expect(movedStart.start == CGPoint(x: -5, y: 7))
        #expect(movedStart.end == CGPoint(x: 100, y: 0))
    }

    // MARK: Shift 拘束

    @Test("Shift で矩形系は正方形になる（向きの符号は保つ）")
    func 正方形拘束() {
        let p = AnnotationGeometry.constrained(
            anchor: CGPoint(x: 10, y: 10), point: CGPoint(x: 70, y: -20), kind: .rect)
        #expect(p == CGPoint(x: 70, y: -50))

        // ハンドルのドラッグでも、角ハンドルは正方形に拘束される。
        let rect = shape(.ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50))
        let resized = AnnotationGeometry.resized(
            rect, handle: .bottomRight, to: CGPoint(x: 80, y: 30), constrain: true)
        let r = AnnotationGeometry.bounds(of: resized)
        #expect(close(r.width, r.height))
        #expect(r.origin == .zero)
    }

    @Test("Shift で線は 45° 刻みになり、長さは保たれる", arguments: [
        (CGPoint(x: 100, y: 10), 0.0),
        (CGPoint(x: 100, y: 90), 45.0),
        (CGPoint(x: 10, y: 100), 90.0),
        (CGPoint(x: -100, y: 5), 180.0),
    ])
    func 角度拘束(point: CGPoint, expectedDegrees: Double) {
        let anchor = CGPoint(x: 0, y: 0)
        let result = AnnotationGeometry.constrained(anchor: anchor, point: point, kind: .line)
        let degrees = atan2(result.y, result.x) * 180 / .pi
        #expect(abs(abs(degrees) - expectedDegrees) < 0.001)
        #expect(close(hypot(result.x, result.y), hypot(point.x, point.y)))
    }

    // MARK: 正規化

    @Test("正規化で矩形系の始点が左上、終点が右下になる")
    func 正規化() {
        let rect = shape(.rect, from: CGPoint(x: 100, y: 80), to: CGPoint(x: 20, y: 10))
        let normalized = AnnotationGeometry.normalized(rect)
        #expect(normalized.start == CGPoint(x: 20, y: 10))
        #expect(normalized.end == CGPoint(x: 100, y: 80))

        // 線・矢印は向きに意味があるので変えない。
        let arrow = shape(.arrow, from: CGPoint(x: 100, y: 80), to: CGPoint(x: 20, y: 10))
        #expect(AnnotationGeometry.normalized(arrow) == arrow)
    }

    // MARK: テキスト

    @Test("テキストは複数行で外接矩形が縦に伸びる")
    func 複数行() {
        let one = Annotation(kind: .text, start: .zero, end: .zero, text: "abc")
        let two = Annotation(kind: .text, start: .zero, end: .zero, text: "abc\nabc")
        let h1 = AnnotationGeometry.bounds(of: one).height
        let h2 = AnnotationGeometry.bounds(of: two).height
        #expect(close(h2, h1 * 2, 0.5))
        #expect(close(AnnotationGeometry.bounds(of: one).width, AnnotationGeometry.bounds(of: two).width))
    }

    @Test("テキストの拡縮ハンドルで文字サイズが比例する")
    func テキスト拡縮() {
        var text = Annotation(kind: .text, start: CGPoint(x: 50, y: 50), end: .zero, text: "Hello")
        text.style.text.size = 20
        let b = AnnotationGeometry.bounds(of: text)
        // 右下ハンドルを幅が 2 倍になる位置へ。左上は固定される。
        let resized = AnnotationGeometry.resized(
            text, handle: .bottomRight, to: CGPoint(x: b.minX + b.width * 2, y: b.minY + b.height * 2))
        #expect(close(CGFloat(resized.style.text.size), 40, 0.001))
        #expect(resized.start == text.start)
        let nb = AnnotationGeometry.bounds(of: resized)
        #expect(nb.width > b.width * 1.8)
    }
}
