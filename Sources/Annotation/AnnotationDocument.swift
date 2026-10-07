import CoreGraphics
import Foundation
import Observation

// 注釈の配列・選択・取り消し／やり直し・層ごとの重なり順を持つドキュメント。
//
// 取り消しは**配列のスナップショット**を積む方式。ドラッグ中に何度も積むと
// 1 回のドラッグが何十回もの取り消しになってしまうため、次の 2 通りを用意する。
//
// - 1 回で終わる操作（追加・削除・複製・種類変更・`mutate` など）は、
//   各メソッドが内部で 1 回だけ積む
// - ドラッグのように連続して更新する操作は、開始時に `beginChange()` を 1 回呼び、
//   途中は `setWithoutHistory(_:)` で履歴なしに書き換え、終了時に
//   `commitChange()`（何も変わっていなければ積んだ履歴を取り消す）を呼ぶ
@MainActor
@Observable
final class AnnotationDocument {

    /// 注釈の配列。**ぼかし・モザイク層が常に図形層より前（配列の先頭側）** に並ぶ。
    /// 描く順（後ろほど手前）でもあるので、層ごとの順序はこの配列のまま保たれる。
    private(set) var annotations: [Annotation] = []

    /// 選択中の注釈 ID。
    var selectedIDs: Set<UUID> = [] {
        didSet {
            if oldValue != selectedIDs { selectionChangedAt = Date() }
        }
    }

    /// 選択が最後に変わった時刻。カラーパネルの遅れて届く変更を弾くのに使う。
    @ObservationIgnored private(set) var selectionChangedAt = Date.distantPast

    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: 参照

    func annotation(id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// 選択中の注釈（配列順＝重なり順）。
    var selectedAnnotations: [Annotation] {
        annotations.filter { selectedIDs.contains($0.id) }
    }

    /// 層ごとの注釈（描画順）。
    var redactionAnnotations: [Annotation] { annotations.filter { $0.layer == .redaction } }
    var figureAnnotations: [Annotation] { annotations.filter { $0.layer == .figure } }

    // MARK: 選択

    func select(_ ids: Set<UUID>) {
        selectedIDs = ids.intersection(Set(annotations.map(\.id)))
    }

    func clearSelection() {
        selectedIDs = []
    }

    /// Shift クリックなどの追加選択。選択済みなら外す。
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else if annotation(id: id) != nil {
            selectedIDs.insert(id)
        }
    }

    // MARK: 履歴

    /// 連続する変更の開始。現在の状態を取り消し履歴に 1 回積む（やり直しは破棄）。
    ///
    /// やり直しの履歴は退避しておく。変化なしで終わったとき（`commitChange()`）に戻すため。
    /// 追加・削除のように `commitChange()` を呼ばない操作では、そのまま破棄になる。
    func beginChange() {
        undoStack.append(annotations)
        stashedRedo = redoStack
        redoStack.removeAll()
    }

    /// `beginChange()` で退避したやり直しの履歴。
    private var stashedRedo: [[Annotation]]?

    /// 連続する変更の終了。開始時から何も変わっていなければ、積んだ履歴を取り消し、
    /// 退避したやり直しも戻す（クリックしただけで履歴が変わらないように）。
    func commitChange() {
        if let last = undoStack.last, last == annotations {
            undoStack.removeLast()
            if let stashedRedo { redoStack = stashedRedo }
        }
        stashedRedo = nil
    }

    /// 履歴を積まずに注釈を差し替える。`beginChange()` 〜 `commitChange()` の間の
    /// ドラッグ中の更新に使う。存在しない ID は無視する。
    func setWithoutHistory(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = Self.sanitized(annotation)
        normalizeLayers()
    }

    /// 履歴を積まずに、指定した注釈（省略時は選択中）をまとめて書き換える。
    /// スライダーのドラッグ中のように連続して更新するとき、`beginChange()` 〜
    /// `commitChange()` の間で使う。
    func mutateWithoutHistory(ids: Set<UUID>? = nil, _ transform: (inout Annotation) -> Void) {
        let targets = ids ?? selectedIDs
        for index in annotations.indices where targets.contains(annotations[index].id) {
            transform(&annotations[index])
            annotations[index] = Self.sanitized(annotations[index])
        }
        normalizeLayers()
    }

    /// 1 回の操作として、指定した注釈（省略時は選択中）をまとめて書き換える。
    /// 履歴は 1 回だけ積む。
    func mutate(ids: Set<UUID>? = nil, _ transform: (inout Annotation) -> Void) {
        let targets = ids ?? selectedIDs
        guard annotations.contains(where: { targets.contains($0.id) }) else { return }
        beginChange()
        for index in annotations.indices where targets.contains(annotations[index].id) {
            transform(&annotations[index])
            annotations[index] = Self.sanitized(annotations[index])
        }
        normalizeLayers()
        commitChange()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        stashedRedo = nil
        redoStack.append(annotations)
        annotations = previous
        dropMissingSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        stashedRedo = nil
        undoStack.append(annotations)
        annotations = next
        dropMissingSelection()
    }

    /// 全消去。履歴も捨てる（ウィンドウを閉じるときの解放用）。
    func removeAll() {
        annotations = []
        selectedIDs = []
        undoStack = []
        redoStack = []
        stashedRedo = nil
    }

    // MARK: 追加・削除・複製

    /// 注釈を追加する。同じ層の最前面に入る。`select` なら追加したものだけを選択する
    /// （描き終えたらそのオブジェクトを選択状態にする、という仕様）。
    func add(_ annotation: Annotation, select: Bool = true) {
        beginChange()
        insertAtFront(annotation)
        if select { selectedIDs = [annotation.id] }
    }

    /// 指定した注釈（省略時は選択中）を削除する。
    func remove(ids: Set<UUID>? = nil) {
        let targets = ids ?? selectedIDs
        guard annotations.contains(where: { targets.contains($0.id) }) else { return }
        beginChange()
        annotations.removeAll { targets.contains($0.id) }
        dropMissingSelection()
    }

    /// 指定した注釈（省略時は選択中）を複製し、複製側を選択する。
    /// 元の位置から `offset` ずらす（重なって複製されたと分からなくならないように）。
    /// - Returns: 複製した注釈の ID（配列順）。
    @discardableResult
    func duplicate(ids: Set<UUID>? = nil, offset: CGSize = CGSize(width: 10, height: 10)) -> [UUID] {
        let targets = ids ?? selectedIDs
        let sources = annotations.filter { targets.contains($0.id) }
        guard !sources.isEmpty else { return [] }
        beginChange()
        var newIDs: [UUID] = []
        for source in sources {
            var copy = AnnotationGeometry.moved(source, by: offset)
            copy.id = UUID()
            insertAtFront(copy)
            newIDs.append(copy.id)
        }
        selectedIDs = Set(newIDs)
        return newIDs
    }

    // MARK: 重なり順

    /// 同じ層の最前面へ。層を越えては動かない。複数選択の相対順は保つ。
    func bringToFront(ids: Set<UUID>? = nil) {
        reorder(ids: ids ?? selectedIDs, toFront: true)
    }

    /// 同じ層の最背面へ。層を越えては動かない。複数選択の相対順は保つ。
    func sendToBack(ids: Set<UUID>? = nil) {
        reorder(ids: ids ?? selectedIDs, toFront: false)
    }

    private func reorder(ids: Set<UUID>, toFront: Bool) {
        guard annotations.contains(where: { ids.contains($0.id) }) else { return }
        // 層ごとに「動かすもの」と「それ以外」に分け、並べ直して層順に連結する。
        // 層をまたぐ入れ替えは起きない。
        var result: [Annotation] = []
        for layer in [AnnotationLayer.redaction, .figure] {
            let inLayer = annotations.filter { $0.layer == layer }
            let moving = inLayer.filter { ids.contains($0.id) }
            let others = inLayer.filter { !ids.contains($0.id) }
            result += toFront ? others + moving : moving + others
        }
        guard result != annotations else { return }
        beginChange()
        annotations = result
    }

    // MARK: 種類変更

    /// 種類を切り替える。図形どうし（矢印・線・四角・円）とぼかし⇔モザイクだけ。
    /// 切り替えられない組み合わせの注釈は変えない。
    func changeKind(to kind: AnnotationKind, ids: Set<UUID>? = nil) {
        mutate(ids: ids) { annotation in
            guard annotation.kind != kind,
                annotation.kind.switchableKinds.contains(kind)
            else { return }
            annotation.kind = kind
            // 「先端なしの矢印」は線と同じ。線から矢印へ切り替えたら先端が
            // 見えるようにする（先端なしのままだと切り替えた意味が分からない）。
            if kind == .arrow, annotation.style.arrowHeads == .none {
                annotation.style.arrowHeads = .end
            }
        }
    }

    // MARK: 内部

    /// 同じ層の最前面に挿入する。ぼかし層は図形層の手前（配列の途中）に入る。
    private func insertAtFront(_ annotation: Annotation) {
        let annotation = Self.sanitized(annotation)
        switch annotation.layer {
        case .figure:
            annotations.append(annotation)
        case .redaction:
            let index = annotations.firstIndex { $0.layer == .figure } ?? annotations.endIndex
            annotations.insert(annotation, at: index)
        }
    }

    /// ぼかし・モザイクの強さを、その種類の下限・上限へ収める（P4-5）。
    /// 追加・書き換えのすべてがここを通るので、弱すぎる強さは文書に入らない。
    private static func sanitized(_ annotation: Annotation) -> Annotation {
        guard annotation.layer == .redaction else { return annotation }
        var result = annotation
        result.style.redaction = annotation.style.redaction.clamped(for: annotation.kind)
        return result
    }

    /// 層の不変条件（範囲加工層が必ず図形層より前）を、層内の順序を保ったまま回復する。
    /// 種類変更で層が変わりうる場合の保険。
    private func normalizeLayers() {
        let sorted =
            annotations.filter { $0.layer == .redaction } + annotations.filter { $0.layer == .figure }
        if sorted != annotations { annotations = sorted }
    }

    private func dropMissingSelection() {
        let existing = Set(annotations.map(\.id))
        selectedIDs = selectedIDs.intersection(existing)
    }
}
