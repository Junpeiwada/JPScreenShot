import CoreGraphics
import Foundation

// キャンバスのマウス操作の判断だけを切り出した純粋関数。
//
// NSView（AnnotationCanvasView）から座標の変換・当たり判定・作成の可否・範囲選択を
// 外に出して、画面なしでテストできるようにしてある。
// 注釈の座標は画像のポイント座標、マウス座標は画面（ビュー）上のポイント。
// 両者は「表示倍率」（表示サイズ ÷ pointSize）で結ばれる。
enum AnnotationInteraction {

    // MARK: 画面上で一定の大きさ

    /// 選択ハンドルの描画サイズ（画面上のポイント）。
    static let handleSize: CGFloat = 8
    /// ハンドルをつかめる半径（画面上のポイント）。描画サイズより少し広く取る。
    static let handleTolerance: CGFloat = 7
    /// オブジェクトのクリックに許す幅（画面上のポイント）。
    static let hitTolerance: CGFloat = 6
    /// 選択枠（破線）の辺をつかめる幅（画面上のポイント）。
    static let frameTolerance: CGFloat = 6
    /// これ未満のドラッグでは新規作成しない・移動を始めない（画面上のポイント）。
    static let minimumDragDistance: CGFloat = 3

    // MARK: 表示倍率

    /// 表示倍率。表示幅 ÷ 画像のポイント幅（等倍なら 1、縮小表示なら 1 未満）。
    /// どちらかが 0 以下のときは 1（0 除算を避ける）。
    static func displayScale(displayWidth: CGFloat, pointWidth: CGFloat) -> CGFloat {
        guard displayWidth > 0, pointWidth > 0 else { return 1 }
        return displayWidth / pointWidth
    }

    /// 画面上のマウス位置を注釈の座標（ポイント）に直す。
    static func annotationPoint(fromView point: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    /// 画面上の長さを注釈の座標系の長さに直す。許容幅を「画面上で一定」にするために使う。
    /// 縮小表示（倍率 0.5）なら 2 倍になる。
    static func annotationLength(fromView length: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return length }
        return length / scale
    }

    // MARK: 新規作成

    /// 始点から終点までのドラッグが、新規作成するのに十分な大きさか。
    /// 距離は画面上のポイントで測る（縮小表示でも同じ手応えにするため）。
    static func isLargeEnoughToCreate(from start: CGPoint, to end: CGPoint, scale: CGFloat) -> Bool {
        hypot(end.x - start.x, end.y - start.y) * scale >= minimumDragDistance
    }

    /// ドラッグから注釈を組み立てる。Shift 拘束（正方形・45°）を掛け、矩形系は正規化する。
    static func makeAnnotation(
        kind: AnnotationKind,
        from anchor: CGPoint,
        to point: CGPoint,
        constrain: Bool,
        style: AnnotationStyle,
        id: UUID = UUID()
    ) -> Annotation {
        let end = constrain
            ? AnnotationGeometry.constrained(anchor: anchor, point: point, kind: kind) : point
        let annotation = Annotation(id: id, kind: kind, start: anchor, end: end, style: style)
        return AnnotationGeometry.normalized(annotation)
    }

    // MARK: 当たり判定

    /// 点の位置にある最前面の注釈。配列は後ろほど手前なので逆順に調べる
    /// （図形層はぼかし・モザイク層より後ろにあるので、重なれば図形が先に当たる）。
    static func topmostHit(
        in annotations: [Annotation],
        at point: CGPoint,
        tolerance: CGFloat
    ) -> Annotation? {
        annotations.last { AnnotationGeometry.hitTest($0, at: point, tolerance: tolerance) }
    }

    /// マウスを押した位置にあるもの。
    enum PressTarget: Equatable {
        /// 選択中の（1 件だけの）注釈のハンドル。
        case handle(AnnotationGeometry.Handle, UUID)
        /// 注釈の本体。
        case object(UUID)
        /// **選択中**の注釈の本体、または選択枠（破線）の辺の近く。ツールによらず移動になる。
        case selectedBody(UUID)
        /// 何もない。
        case none

        /// 注釈の本体（選択中のものを含む）を指すときの ID。
        var annotationID: UUID? {
            switch self {
            case .object(let id), .selectedBody(let id): id
            case .handle, .none: nil
            }
        }
    }

    /// 選択枠（破線の矩形）。描画（drawSelectionOverlay）と当たり判定で同じ矩形を使う。
    ///
    /// 線・矢印は外接矩形が高さ 0 になりうるので、線の太さの半分＋余白だけ外へ広げる。
    /// それ以外は外接矩形そのまま。
    static func selectionFrame(of annotation: Annotation) -> CGRect {
        let bounds = AnnotationGeometry.bounds(of: annotation)
        guard annotation.kind.isLinear else { return bounds }
        let margin = CGFloat(annotation.style.lineWidth) / 2 + 4
        return bounds.insetBy(dx: -margin, dy: -margin)
    }

    /// 点が選択枠の辺から許容幅以内（辺をまたいだ帯の中）にあるか。
    /// 枠が許容幅の 2 倍より小さいときは、枠の内側全体が帯になる。
    static func isNearSelectionFrameEdge(
        _ annotation: Annotation, at point: CGPoint, tolerance: CGFloat
    ) -> Bool {
        let frame = selectionFrame(of: annotation)
        guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        return !frame.insetBy(dx: tolerance, dy: tolerance).contains(point)
    }

    /// ツールの種類（押したときの判定が変わる）。
    enum PressMode: Equatable {
        case select
        /// 矢印・線・四角・円・ぼかし・モザイク。
        case shape
        case text
    }

    /// 押したときに実際に起きること。**カーソルと mouseDown の両方がこれを使う**ので、
    /// 表示と実際の動きがずれない。
    enum PressAction: Equatable {
        /// ハンドルで変形する。
        case resize(AnnotationGeometry.Handle, UUID)
        /// 選択中のものを動かす（本体・枠の帯）。
        case moveSelected(UUID)
        /// 未選択のものを選ぶ。クリックで選択、ドラッグなら選択してそのまま移動。
        case pickObject(UUID)
        /// テキストツールで既存の注釈の上を押した（テキストなら編集、他なら新規テキスト）。
        case textOnObject(UUID)
        /// 新規作成（描画ツール）。
        case create
        /// その位置にテキストを置く（テキストツール）。
        case placeText
        /// 範囲選択（選択ツールで何もない所）。
        case marquee
        /// Shift 押下中に選択中のものを押した。選択の追加／解除（移動はしない）。
        case toggleSelection(UUID)
        /// 何も起きない（Shift 押下中のテキストツールで選択中のものを押した）。
        case nothing
    }

    /// 押した対象とツールから、起きることを決める。
    /// - Parameter shift: Shift 押下中か。選択中のものは、移動ではなく追加／解除になる。
    static func pressAction(
        for target: PressTarget, mode: PressMode, shift: Bool = false
    ) -> PressAction {
        switch target {
        case .handle(let handle, let id):
            return .resize(handle, id)
        case .selectedBody(let id):
            if shift { return mode == .text ? .nothing : .toggleSelection(id) }
            return .moveSelected(id)
        case .object(let id):
            return mode == .text ? .textOnObject(id) : .pickObject(id)
        case .none:
            switch mode {
            case .select: return .marquee
            case .shape: return .create
            case .text: return .placeText
            }
        }
    }

    /// 面で当たる注釈か（テキスト・ぼかし・モザイク・塗りありの四角/円）。
    /// 線・矢印、塗りなしの四角/円は、当たるのが線の付近だけなので面ではない。
    static func isAreaBody(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .arrow, .line: false
        case .rect, .ellipse: annotation.style.fill != .none
        case .text, .blur, .mosaic: true
        }
    }

    /// 押した位置の対象を決める。優先順は
    /// 1. 1 件選択中のハンドル（変形）
    /// 2. 選択中の本体より手前にある**未選択**の注釈の本体（`.object`。選び直せるように）
    /// 3. 選択中の注釈の本体（移動）
    /// 4. 選択枠（破線）の辺の近く（移動。本体に当たらなかったときだけ）
    /// 5. 最前面の注釈の本体（`.object`）
    /// 6. 何もない
    ///
    /// ハンドルはツールによらず最優先（描画ツール中でも変形になる）。
    ///
    /// ハンドルを出すのは 1 件だけ選択しているときだけ。複数選択の一括変形は
    /// 幾何側が対応していないので、複数のときはハンドルを持たない。
    ///
    /// - Parameter mode: 現在のツールの種類。
    ///   - `.select`: 本体のどこでも選べる・動かせる。
    ///   - `.shape`（描画ツール）: 面の注釈（`isAreaBody`）は内部では選べず・動かせず
    ///     （押せば新規作成）、外接枠の辺の帯だけが対象。線・矢印・塗りなしの四角/円は線の上が対象。
    ///   - `.text`: 選択中の面は帯だけが移動。未選択の本体はどこでも対象（編集に使う）。
    static func pressTarget(
        annotations: [Annotation],
        selectedIDs: Set<UUID>,
        at point: CGPoint,
        scale: CGFloat,
        mode: PressMode = .select
    ) -> PressTarget {
        let areaNeedsEdge = mode != .select
        let edgeOnlyPick = mode == .shape
        let selected = annotations.filter { selectedIDs.contains($0.id) }
        if selected.count == 1, let only = selected.first,
            let handle = AnnotationGeometry.handle(
                at: point, of: only,
                tolerance: annotationLength(fromView: handleTolerance, scale: scale))
        {
            return .handle(handle, only.id)
        }
        let bodyTolerance = annotationLength(fromView: hitTolerance, scale: scale)
        let edgeTolerance = annotationLength(fromView: frameTolerance, scale: scale)

        // 描画ツールでは「見た目に合わせる」。手前から見て、不透明な面の内部（枠の帯でない所）に
        // 先に当たったら、それより奥は隠れているので対象にしない（押せば新規作成）。
        // テキストと半透明の塗りは後ろが見えるので遮らない。
        var blockIndex = -1
        if edgeOnlyPick {
            for index in annotations.indices.reversed() {
                let annotation = annotations[index]
                guard isOpaqueArea(annotation),
                    AnnotationGeometry.hitTest(annotation, at: point, tolerance: bodyTolerance),
                    !isNearPickBand(annotation, at: point, tolerance: edgeTolerance)
                else { continue }
                blockIndex = index
                break
            }
        }
        let valid = Array(annotations[(blockIndex + 1)...])

        // 押して選べる最前面。描画ツールでは、面は枠の辺の帯だけが対象。
        let top = valid.last { annotation in
            if edgeOnlyPick && isAreaBody(annotation) {
                return isNearPickBand(annotation, at: point, tolerance: edgeTolerance)
            }
            return AnnotationGeometry.hitTest(annotation, at: point, tolerance: bodyTolerance)
        }
        // 移動の対象になる選択中の本体（手前のものを優先）。
        let selectedBody = valid.last {
            selectedIDs.contains($0.id)
                && AnnotationGeometry.hitTest($0, at: point, tolerance: bodyTolerance)
                && !(areaNeedsEdge && isAreaBody($0))
        }
        // 選択中より手前にある未選択の注釈は、クリックで選べるようにする。
        if let top, !selectedIDs.contains(top.id) {
            let topIndex = valid.firstIndex { $0.id == top.id } ?? 0
            let selectedIndex = selectedBody.flatMap { body in
                valid.firstIndex { $0.id == body.id }
            }
            if selectedIndex == nil || topIndex > selectedIndex! { return .object(top.id) }
        }
        if let selectedBody { return .selectedBody(selectedBody.id) }
        if let edge = valid.last(where: {
            selectedIDs.contains($0.id)
                && isNearSelectionFrameEdge($0, at: point, tolerance: edgeTolerance)
        }) {
            return .selectedBody(edge.id)
        }
        if let top { return .object(top.id) }
        return .none
    }

    /// 不透明に描かれる面か（塗りつぶしの四角/円・ぼかし・モザイク）。後ろが見えない。
    static func isOpaqueArea(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rect, .ellipse: annotation.style.fill == .solid
        case .blur, .mosaic: true
        case .arrow, .line, .text: false
        }
    }

    /// 楕円形の注釈か（円・形が楕円のぼかし/モザイク）。
    static func isEllipseShaped(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .ellipse: true
        case .blur, .mosaic: annotation.style.redaction.shape == .ellipse
        default: false
        }
    }

    /// 未選択の面を押して選べる帯。楕円形は楕円の輪郭からの距離、それ以外は選択枠の辺。
    /// （角の何もない所を拾わないため。選択中の移動の帯は、見えている破線の枠に合わせて
    /// `isNearSelectionFrameEdge`。）
    static func isNearPickBand(
        _ annotation: Annotation, at point: CGPoint, tolerance: CGFloat
    ) -> Bool {
        guard isEllipseShaped(annotation) else {
            return isNearSelectionFrameEdge(annotation, at: point, tolerance: tolerance)
        }
        let frame = selectionFrame(of: annotation)
        return ellipseContains(frame, expandedBy: tolerance, point)
            && !ellipseContains(frame, expandedBy: -tolerance, point)
    }

    private static func ellipseContains(_ rect: CGRect, expandedBy margin: CGFloat, _ p: CGPoint) -> Bool {
        let a = rect.width / 2 + margin
        let b = rect.height / 2 + margin
        guard a > 0, b > 0 else { return false }
        let dx = (p.x - rect.midX) / a
        let dy = (p.y - rect.midY) / b
        return dx * dx + dy * dy <= 1
    }

    /// ダブルクリックで編集を再開するテキスト。**ツールによらず**（選択ツールと同じ判定で求める）。
    /// ハンドル上は変形を優先するので nil。
    static func textToEditOnDoubleClick(
        annotations: [Annotation], selectedIDs: Set<UUID>, at point: CGPoint, scale: CGFloat
    ) -> UUID? {
        let target = pressTarget(
            annotations: annotations, selectedIDs: selectedIDs, at: point, scale: scale,
            mode: .select)
        guard let id = target.annotationID,
            annotations.first(where: { $0.id == id })?.kind == .text
        else { return nil }
        return id
    }

    // MARK: 小窓を開く条件

    /// マウスを離したときの結果の種類。
    enum ReleaseOutcome: Equatable {
        /// クリックで選んだ（ドラッグなし）。
        case clicked
        /// 移動し終えた。
        case moved
        /// 変形し終えた。
        case resized
        /// 新規作成し終えた。
        case created
        /// 範囲選択し終えた。
        case marquee
        /// テキスト編集を始めた。
        case textEditing
    }

    /// 離したときに小窓（StylePopover）を開く（開いていれば位置を合わせ直す）か。
    /// クリック選択・移動・変形の直後だけ、選択が 1 件以上のとき開く。
    /// 新規作成・範囲選択・テキスト編集の直後は、続ける操作の邪魔なので開かない。
    /// （矢印キーでの移動は離す操作ではないので対象外＝開かない。）
    static func opensPopover(after outcome: ReleaseOutcome, selectionCount: Int) -> Bool {
        guard selectionCount > 0 else { return false }
        switch outcome {
        case .clicked, .moved, .resized: return true
        case .created, .marquee, .textEditing: return false
        }
    }

    // MARK: 範囲選択

    /// 範囲（注釈の座標）に触れている注釈の ID。
    ///
    /// 線・矢印の外接矩形は高さ 0 になりうるので、線の太さの半分（最低 1pt）だけ
    /// 広げてから交差を見る（交差判定は面積 0 の矩形を拾わない）。
    static func marqueeSelection(in annotations: [Annotation], rect: CGRect) -> Set<UUID> {
        var result: Set<UUID> = []
        for annotation in annotations {
            let margin = max(CGFloat(annotation.style.lineWidth) / 2, 1)
            let box = AnnotationGeometry.bounds(of: annotation).insetBy(dx: -margin, dy: -margin)
            if box.intersects(rect) { result.insert(annotation.id) }
        }
        return result
    }
}
