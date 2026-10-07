import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// キャンバスの操作判断（表示倍率・作成の可否・押した対象・範囲選択）は純粋関数。
// 縮小表示でも画面上の手応えが変わらないことを、倍率を変えて確かめる。
@Suite("注釈キャンバスの操作判断")
struct AnnotationInteractionTests {

    private func box(_ kind: AnnotationKind = .rect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat)
        -> Annotation
    {
        var style = AnnotationStyle()
        style.lineWidth = 4
        return Annotation(
            kind: kind, start: CGPoint(x: x, y: y), end: CGPoint(x: x + w, y: y + h), style: style)
    }

    // MARK: ツール

    @Test("描画ツールは対応する種類を持ち、選択ツールは持たない")
    func ツールと種類() {
        #expect(AnnotationTool.select.kind == nil)
        #expect(AnnotationTool.arrow.kind == .arrow)
        #expect(AnnotationTool.mosaic.kind == .mosaic)
        // 種類ごとにちょうど 1 ツール。
        let kinds = AnnotationTool.allCases.compactMap(\.kind)
        #expect(Set(kinds) == Set(AnnotationKind.allCases))
        #expect(kinds.count == AnnotationKind.allCases.count)
    }

    @Test("すべてのツールが使える（テキストを含む）")
    func 全ツールが有効() {
        #expect(AnnotationTool.allCases.count == 8)
        #expect(AnnotationTool.text.kind == .text)
    }

    @Test("新規作成の既定スタイルは赤・太さ 5・影あり")
    func 既定スタイル() {
        let style = AnnotationStyle.initialDrawingStyle
        #expect(style.lineWidth == 5)
        #expect(style.shadow.isOn)
        #expect(abs(style.color.red - 1.0) < 0.001)
        #expect(abs(style.color.green - 0x3B / 255) < 0.001)
        #expect(abs(style.color.blue - 0x30 / 255) < 0.001)
    }

    // MARK: 表示倍率

    @Test("表示倍率は表示幅 ÷ ポイント幅。異常値は 1")
    func 表示倍率() {
        #expect(AnnotationInteraction.displayScale(displayWidth: 400, pointWidth: 400) == 1)
        #expect(AnnotationInteraction.displayScale(displayWidth: 200, pointWidth: 400) == 0.5)
        #expect(AnnotationInteraction.displayScale(displayWidth: 0, pointWidth: 400) == 1)
        #expect(AnnotationInteraction.displayScale(displayWidth: 200, pointWidth: 0) == 1)
    }

    @Test("マウス座標は表示倍率で割って注釈座標にする")
    func 座標変換() {
        let p = AnnotationInteraction.annotationPoint(fromView: CGPoint(x: 50, y: 20), scale: 0.5)
        #expect(p == CGPoint(x: 100, y: 40))
        let same = AnnotationInteraction.annotationPoint(fromView: CGPoint(x: 50, y: 20), scale: 1)
        #expect(same == CGPoint(x: 50, y: 20))
    }

    // MARK: 作成の可否

    @Test("3pt 未満のドラッグは作らない（画面上の距離で判定）")
    func 小さいドラッグ() {
        let a = CGPoint(x: 10, y: 10)
        #expect(!AnnotationInteraction.isLargeEnoughToCreate(from: a, to: CGPoint(x: 12, y: 10), scale: 1))
        #expect(AnnotationInteraction.isLargeEnoughToCreate(from: a, to: CGPoint(x: 13, y: 10), scale: 1))
        // 縮小表示（0.5）では注釈座標で 5 動かして画面上 2.5 なので足りない。
        #expect(!AnnotationInteraction.isLargeEnoughToCreate(from: a, to: CGPoint(x: 15, y: 10), scale: 0.5))
        #expect(AnnotationInteraction.isLargeEnoughToCreate(from: a, to: CGPoint(x: 16, y: 10), scale: 0.5))
    }

    @Test("ドラッグから作る注釈は矩形なら正規化され、Shift で正方形になる")
    func 注釈の組み立て() {
        let a = AnnotationInteraction.makeAnnotation(
            kind: .rect, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20),
            constrain: false, style: AnnotationStyle())
        #expect(a.start == CGPoint(x: 10, y: 20))
        #expect(a.end == CGPoint(x: 50, y: 50))

        let square = AnnotationInteraction.makeAnnotation(
            kind: .ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 10),
            constrain: true, style: AnnotationStyle())
        let size = AnnotationGeometry.bounds(of: square).size
        #expect(size.width == size.height)

        // 線は向きに意味があるので正規化しない。
        let line = AnnotationInteraction.makeAnnotation(
            kind: .line, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20),
            constrain: false, style: AnnotationStyle())
        #expect(line.start == CGPoint(x: 50, y: 50))
    }

    // MARK: 押した対象

    @Test("最前面の注釈が先に当たる（図形がぼかしより優先）")
    func 最前面() {
        let blur = box(.blur, 0, 0, 100, 100)
        let rect = box(.rect, 0, 0, 100, 100)
        // 配列はぼかし層が先頭側。
        let hit = AnnotationInteraction.topmostHit(
            in: [blur, rect], at: CGPoint(x: 0, y: 50), tolerance: 3)
        #expect(hit?.id == rect.id)
        // 枠の内側（塗りなし）は図形に当たらず、ぼかしに当たる。
        let inner = AnnotationInteraction.topmostHit(
            in: [blur, rect], at: CGPoint(x: 50, y: 50), tolerance: 3)
        #expect(inner?.id == blur.id)
    }

    @Test("1 件選択中はハンドルが本体より優先される")
    func ハンドル優先() {
        let rect = box(.rect, 0, 0, 100, 100)
        let target = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: CGPoint(x: 100, y: 100), scale: 1)
        #expect(target == .handle(.bottomRight, rect.id))
        // 選択されていなければ本体。
        let unselected = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [], at: CGPoint(x: 100, y: 100), scale: 1)
        #expect(unselected == .object(rect.id))
    }

    @Test("複数選択ではハンドルを出さない")
    func 複数選択はハンドル無し() {
        let a = box(.rect, 0, 0, 100, 100)
        let b = box(.rect, 200, 0, 50, 50)
        let target = AnnotationInteraction.pressTarget(
            annotations: [a, b], selectedIDs: [a.id, b.id], at: CGPoint(x: 100, y: 100), scale: 1)
        // ハンドルではなく、選択中の本体（移動）になる。
        #expect(target == .selectedBody(a.id))
    }

    @Test("ハンドルの許容幅は画面上で一定（縮小表示では注釈座標で広がる）")
    func 許容幅は画面上で一定() {
        let rect = box(.rect, 0, 0, 100, 100)
        // 角から注釈座標で 10 離れた位置。等倍だと許容 7 の外、0.5 倍なら許容 14 の中。
        let point = CGPoint(x: 110, y: 100)
        let atFull = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: point, scale: 1)
        #expect(atFull == .none)
        let atHalf = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: point, scale: 0.5)
        #expect(atHalf == .handle(.bottomRight, rect.id))
    }

    @Test("選択中の線は、選択枠の辺の近くを押すと移動（selectedBody）になる")
    func 線の選択枠の辺は移動() {
        // 水平な線 (0,50)-(100,50)、太さ 5。選択枠は余白込みで y = 50 ± (2.5 + 4)。
        var line = Annotation(
            kind: .line, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        line.style.lineWidth = 5
        let frame = AnnotationInteraction.selectionFrame(of: line)
        #expect(frame.minY == 50 - 6.5 && frame.maxY == 50 + 6.5)
        // 枠の上辺（y = 43.5）から 3 離れた位置（辺の帯の中）。線そのものからは遠い。
        let nearEdge = AnnotationInteraction.pressTarget(
            annotations: [line], selectedIDs: [line.id], at: CGPoint(x: 50, y: 40.5), scale: 1)
        #expect(nearEdge == .selectedBody(line.id))
        // 選択されていなければ従来どおり何も当たらない。
        let unselected = AnnotationInteraction.pressTarget(
            annotations: [line], selectedIDs: [], at: CGPoint(x: 50, y: 40.5), scale: 1)
        #expect(unselected == .none)
        // 枠から遠ければ none。
        let far = AnnotationInteraction.pressTarget(
            annotations: [line], selectedIDs: [line.id], at: CGPoint(x: 50, y: 20), scale: 1)
        #expect(far == .none)
    }

    @Test("選択中の矩形の枠の内側の何もない所は移動にならない")
    func 枠の内側は移動にならない() {
        let rect = box(.rect, 0, 0, 100, 100)
        let inside = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: CGPoint(x: 50, y: 50), scale: 1)
        #expect(inside == .none)
        // 枠の辺の外側 4 までは移動（許容 6）。
        let outsideEdge = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: CGPoint(x: 25, y: -4), scale: 1)
        #expect(outsideEdge == .selectedBody(rect.id))
    }

    @Test("枠の辺の許容幅は画面上で一定（縮小表示では注釈座標で広がる）")
    func 枠の許容幅は画面上で一定() {
        let rect = box(.rect, 0, 0, 100, 100)
        let point = CGPoint(x: 25, y: -10)
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [rect], selectedIDs: [rect.id], at: point, scale: 1) == .none)
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [rect], selectedIDs: [rect.id], at: point, scale: 0.5)
                == .selectedBody(rect.id))
    }

    @Test("ハンドルは選択枠の辺より優先される")
    func ハンドルは枠より優先() {
        let rect = box(.rect, 0, 0, 100, 100)
        // 角のハンドル上は枠の辺でもあるが、変形が優先。
        let target = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: CGPoint(x: 100, y: 100), scale: 1)
        #expect(target == .handle(.bottomRight, rect.id))
        // 辺の中央でもハンドル（top）が先。
        let top = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [rect.id], at: CGPoint(x: 50, y: 2), scale: 1)
        #expect(top == .handle(.top, rect.id))
    }

    @Test("複数選択では、選択中のどれかの本体・枠の辺で移動になる")
    func 複数選択の移動() {
        let a = box(.rect, 0, 0, 100, 100)
        let b = box(.rect, 200, 0, 50, 50)
        let target = AnnotationInteraction.pressTarget(
            annotations: [a, b], selectedIDs: [a.id, b.id], at: CGPoint(x: 225, y: 53), scale: 1)
        #expect(target == .selectedBody(b.id))
    }

    @Test("選択中のぼかしより手前の未選択の矢印は、クリックで選べる")
    func 手前の未選択は選べる() {
        let blur = box(.blur, 0, 0, 100, 100)
        let arrow = Annotation(
            kind: .arrow, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        // 配列は後ろほど手前（図形層はぼかし層より後ろ）。
        let target = AnnotationInteraction.pressTarget(
            annotations: [blur, arrow], selectedIDs: [blur.id], at: CGPoint(x: 50, y: 50),
            scale: 1)
        #expect(target == .object(arrow.id))
        // 矢印も選択中なら、移動（手前の矢印）。
        let both = AnnotationInteraction.pressTarget(
            annotations: [blur, arrow], selectedIDs: [blur.id, arrow.id],
            at: CGPoint(x: 50, y: 50), scale: 1)
        #expect(both == .selectedBody(arrow.id))
    }

    @Test("描画ツール中は面の内部では移動にならず、枠の辺の帯だけが移動")
    func 描画ツールの面() {
        let blur = box(.blur, 0, 0, 100, 100)
        let inside = CGPoint(x: 50, y: 50)
        // 選択ツール: 本体のどこでも移動。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [blur], selectedIDs: [blur.id], at: inside, scale: 1)
                == .selectedBody(blur.id))
        // 描画ツール: 内部は何も当たらない（押せば新規作成）。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [blur], selectedIDs: [blur.id], at: inside, scale: 1,
                mode: .shape) == .none)
        // 描画ツールでも、枠の辺の帯は移動。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [blur], selectedIDs: [blur.id], at: CGPoint(x: 25, y: 3), scale: 1,
                mode: .shape) == .selectedBody(blur.id))
        // 線は描画ツールでも本体で移動。
        let line = Annotation(
            kind: .line, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line], selectedIDs: [line.id], at: CGPoint(x: 50, y: 50), scale: 1,
                mode: .shape) == .selectedBody(line.id))
    }

    @Test("描画ツールでは、未選択の面は枠の辺の帯だけ選べ、内部は新規作成")
    func 描画ツールの未選択() {
        let blur = box(.blur, 0, 0, 100, 100)
        let rect = box(.rect, 200, 0, 100, 100)  // 塗りなし
        let line = Annotation(
            kind: .line, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 100, y: 300))
        let all = [blur, rect, line]
        func target(_ x: CGFloat, _ y: CGFloat, _ mode: AnnotationInteraction.PressMode)
            -> AnnotationInteraction.PressTarget
        {
            AnnotationInteraction.pressTarget(
                annotations: all, selectedIDs: [], at: CGPoint(x: x, y: y), scale: 1, mode: mode)
        }
        // ぼかしの内部: 選択ツールなら選べるが、描画ツールでは何も当たらない（新規作成）。
        #expect(target(50, 50, .select) == .object(blur.id))
        #expect(target(50, 50, .shape) == .none)
        // ぼかしの枠の辺の帯は選べる。
        #expect(target(50, 2, .shape) == .object(blur.id))
        // 塗りなしの四角は線の上、線は本体の上で選べる。内部は新規作成。
        #expect(target(250, 0, .shape) == .object(rect.id))
        #expect(target(250, 50, .shape) == .none)
        #expect(target(50, 300, .shape) == .object(line.id))
        // テキストツールは従来どおり、未選択の本体のどこでも対象。
        #expect(target(50, 50, .text) == .object(blur.id))
    }

    @Test("押したときの動き（カーソルと mouseDown 共通）")
    func 押したときの動き() {
        let id = UUID()
        typealias A = AnnotationInteraction
        #expect(A.pressAction(for: .handle(.top, id), mode: .shape) == .resize(.top, id))
        #expect(A.pressAction(for: .selectedBody(id), mode: .shape) == .moveSelected(id))
        #expect(A.pressAction(for: .selectedBody(id), mode: .select) == .moveSelected(id))
        #expect(A.pressAction(for: .object(id), mode: .select) == .pickObject(id))
        #expect(A.pressAction(for: .object(id), mode: .shape) == .pickObject(id))
        #expect(A.pressAction(for: .object(id), mode: .text) == .textOnObject(id))
        #expect(A.pressAction(for: .none, mode: .select) == .marquee)
        #expect(A.pressAction(for: .none, mode: .shape) == .create)
        #expect(A.pressAction(for: .none, mode: .text) == .placeText)
    }

    // MARK: 描画ツールの遮蔽（見た目に合わせる）

    private func filledRect(_ fill: FillMode) -> Annotation {
        var rect = box(.rect, 0, 0, 100, 100)
        rect.style.fill = fill
        return rect
    }

    private var hiddenLine: Annotation {
        Annotation(kind: .line, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
    }

    @Test("塗りありの四角が手前なら、描画ツールで内部を押しても後ろの線は選べない")
    func 不透明な面は後ろを隠す() {
        let line = hiddenLine
        let rect = filledRect(.solid)
        let inside = CGPoint(x: 50, y: 50)
        // 選択ツールは最前面優先のまま（塗りありの四角が当たる）。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line, rect], selectedIDs: [], at: inside, scale: 1, mode: .select)
                == .object(rect.id))
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line, rect], selectedIDs: [], at: inside, scale: 1, mode: .shape)
                == .none)
        // 後ろの線が選択中でも、隠れているので移動にならない。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line, rect], selectedIDs: [line.id], at: inside, scale: 1,
                mode: .shape) == .none)
        // 四角の枠の帯なら四角を選べる。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line, rect], selectedIDs: [], at: CGPoint(x: 50, y: 2), scale: 1,
                mode: .shape) == .object(rect.id))
    }

    @Test("半透明の塗りの内部では、後ろの線を選べる")
    func 半透明は後ろを隠さない() {
        let line = hiddenLine
        let rect = filledRect(.translucent)
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [line, rect], selectedIDs: [], at: CGPoint(x: 50, y: 50), scale: 1,
                mode: .shape) == .object(line.id))
    }

    @Test("ぼかし同士の重なりでも、手前の内部では後ろの枠の帯に当たらない")
    func ぼかしの重なり() {
        let back = box(.blur, 0, 0, 100, 100)
        let front = box(.blur, 20, 20, 200, 200)
        // 後ろのぼかしの枠の辺（x = 100 付近）は、手前のぼかしの内部に隠れている。
        let target = AnnotationInteraction.pressTarget(
            annotations: [back, front], selectedIDs: [back.id], at: CGPoint(x: 100, y: 60),
            scale: 1, mode: .shape)
        #expect(target == .none)
    }

    @Test("楕円形の面の帯は輪郭からの距離（外接枠の角は拾わない）")
    func 楕円の帯() {
        var ellipse = box(.ellipse, 0, 0, 100, 100)
        ellipse.style.fill = .solid
        func target(_ x: CGFloat, _ y: CGFloat) -> AnnotationInteraction.PressTarget {
            AnnotationInteraction.pressTarget(
                annotations: [ellipse], selectedIDs: [], at: CGPoint(x: x, y: y), scale: 1,
                mode: .shape)
        }
        // 外接枠の角（楕円の外）は何もない。
        #expect(target(2, 2) == .none)
        // 楕円の輪郭の上は選べ、内部は新規作成。
        #expect(target(50, 0) == .object(ellipse.id))
        #expect(target(50, 50) == .none)
    }

    @Test("ダブルクリックのテキスト編集はツールによらない")
    func ダブルクリックの編集() {
        var text = Annotation(kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 10))
        text.text = "テスト"
        let bounds = AnnotationGeometry.bounds(of: text)
        let inside = CGPoint(x: bounds.midX, y: bounds.midY)
        // 描画ツール（.shape）の判定では内部は当たらないが、ダブルクリックは選択ツールの判定で求める。
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [text], selectedIDs: [], at: inside, scale: 1, mode: .shape)
                == .none)
        #expect(
            AnnotationInteraction.textToEditOnDoubleClick(
                annotations: [text], selectedIDs: [], at: inside, scale: 1) == text.id)
        // テキスト以外・何もない所は nil。
        let rect = box(.rect, 200, 200, 50, 50)
        #expect(
            AnnotationInteraction.textToEditOnDoubleClick(
                annotations: [rect], selectedIDs: [], at: CGPoint(x: 200, y: 225), scale: 1) == nil)
    }

    @Test("テキストツールの判定は未選択の本体のどこでも対象")
    func テキストモード() {
        let blur = box(.blur, 0, 0, 100, 100)
        #expect(
            AnnotationInteraction.pressTarget(
                annotations: [blur], selectedIDs: [], at: CGPoint(x: 50, y: 50), scale: 1,
                mode: .text) == .object(blur.id))
        #expect(
            AnnotationInteraction.pressAction(for: .object(blur.id), mode: .text)
                == .textOnObject(blur.id))
    }

    @Test("Shift 押下中、選択中のものは移動ではなく追加／解除になる")
    func shiftの押したときの動き() {
        let id = UUID()
        typealias A = AnnotationInteraction
        #expect(
            A.pressAction(for: .selectedBody(id), mode: .select, shift: true)
                == .toggleSelection(id))
        #expect(
            A.pressAction(for: .selectedBody(id), mode: .shape, shift: true)
                == .toggleSelection(id))
        #expect(A.pressAction(for: .selectedBody(id), mode: .text, shift: true) == .nothing)
        // Shift なしは移動のまま。ハンドルは Shift でも変形。
        #expect(A.pressAction(for: .selectedBody(id), mode: .shape) == .moveSelected(id))
        #expect(A.pressAction(for: .handle(.top, id), mode: .shape, shift: true) == .resize(.top, id))
    }

    @Test("小窓を開く条件: クリック選択・移動・変形の直後だけ（選択 1 件以上）")
    func 小窓を開く条件() {
        typealias A = AnnotationInteraction
        for outcome: A.ReleaseOutcome in [.clicked, .moved, .resized] {
            #expect(A.opensPopover(after: outcome, selectionCount: 1))
            #expect(!A.opensPopover(after: outcome, selectionCount: 0))
        }
        for outcome: A.ReleaseOutcome in [.created, .marquee, .textEditing] {
            #expect(!A.opensPopover(after: outcome, selectionCount: 1))
        }
    }

    @Test("何もない所は none")
    func 空白() {
        let rect = box(.rect, 0, 0, 100, 100)
        let target = AnnotationInteraction.pressTarget(
            annotations: [rect], selectedIDs: [], at: CGPoint(x: 300, y: 300), scale: 1)
        #expect(target == .none)
    }

    // MARK: 範囲選択

    @Test("範囲に触れた注釈を選ぶ。高さ 0 の線も拾う")
    func 範囲選択() {
        let inside = box(.rect, 10, 10, 20, 20)
        let outside = box(.rect, 200, 200, 20, 20)
        let flatLine = Annotation(
            kind: .line, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        let ids = AnnotationInteraction.marqueeSelection(
            in: [inside, outside, flatLine], rect: CGRect(x: 0, y: 0, width: 60, height: 60))
        #expect(ids == [inside.id, flatLine.id])
    }
}
