import AppKit
import Observation
import SwiftUI

// 元画像と注釈を描き、マウス・キー操作を受けるキャンバス。
//
// マウスのドラッグ・キー入力・カーソルを細かく扱うため、SwiftUI ではなく
// AppKit の NSView で作る（実装計画「ビューの構成」）。
//
// 座標は 3 つある。混ぜないこと。
// - ビュー座標: この NSView の座標（flipped なので左上原点・y 下向き。画面上のポイント）
// - 注釈座標: 画像のポイント座標（Annotation が持つ値）
// - 両者は「表示倍率」（ビューの幅 ÷ 画像のポイント幅）で結ばれる。
//   等倍表示なら 1、縮小表示なら 1 未満。ビューのサイズは SwiftUI 側が決めるので、
//   倍率は毎回ビューの幅から求める（持ち回さないので表示とずれない）。

// MARK: - SwiftUI への橋渡し

/// ResultView の画像欄に置くキャンバス。サイズは呼び出し側の `.frame` で決める。
struct AnnotationCanvas: NSViewRepresentable {
    let editor: AnnotationEditor
    let image: CGImage
    /// 画像のポイント寸法（`CaptureResult.pointSize`）。表示倍率の基準。
    let pointSize: CGSize

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(editor: editor, image: image, pointSize: pointSize)
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        // 画像・エディタはウィンドウの間ずっと同じ。サイズは setFrameSize で追従する。
    }
}

// MARK: - キャンバス

@MainActor
final class AnnotationCanvasView: NSView, NSMenuItemValidation {

    // 実装は責務ごとに `AnnotationCanvasView+*.swift` の extension に分けてある
    // （Drawing / Mouse / Cursor / Keyboard / Menu / TextEditing）。
    // Swift は extension に保存プロパティを置けず、private は別ファイルから見えないので、
    // 状態は全部ここに集め、拡張から触るものは internal にしてある。
    // ただしキャンバスの外（ResultView など）からは触らないこと。

    let editor: AnnotationEditor
    let pointSize: CGSize

    var document: AnnotationDocument { editor.document }

    private let baseView = BaseImageView()
    private let overlay = AnnotationOverlayView()

    /// 注釈・選択枠を描き直す。元画像はレイヤーなので描き直さない。
    func invalidate() {
        overlay.needsDisplay = true
    }

    // MARK: 操作の状態

    /// ドラッグ中の操作。マウスを押した時点で決まり、離すまで変わらない。
    enum Interaction {
        case idle
        /// 描画ツールで、何もない所・面の内部を押した。ドラッグが 3pt を超えたら `draft` を作り始める。
        /// 超えないまま離したらクリックとして、Shift なしなら選択を外す。
        case create(kind: AnnotationKind, anchor: CGPoint, shift: Bool)
        /// 選択中を動かす。`origins` はドラッグ開始時の注釈（毎回ここからの差分で動かす）。
        /// `collapseTo` は、複数選択のうちの 1 件を動かさずクリックしたとき、
        /// その 1 件だけの選択にするための ID。
        /// `clickAction` は、動かさずに離したときの動作（テキストツール用。下の `ClickAction`）。
        case move(origins: [Annotation], start: CGPoint, collapseTo: UUID?, clickAction: ClickAction?)
        /// ハンドルで変形する。`original` はドラッグ開始時の注釈。`start` は押した位置、
        /// `grabOffset` は「押した位置 − ハンドル中心」。ハンドルの端を押しても形が
        /// 跳ねないよう、変形はこの差を保った位置で計算する。
        case resize(
            original: Annotation, handle: AnnotationGeometry.Handle, start: CGPoint,
            grabOffset: CGSize)
        /// 空白からの範囲選択。
        case marquee(start: CGPoint, additive: Bool, base: Set<UUID>)
    }

    /// 選択中のものを押して動かさずに離したときの、テキストツール特有の動作。
    enum ClickAction {
        /// 選択中の既存テキストを編集にする。
        case editText(Annotation)
        /// その位置に新しいテキストを置く（テキスト以外の選択中の上）。
        case newText(at: CGPoint)
    }

    var interaction: Interaction = .idle
    /// 離したときに（選択が 1 件以上なら）小窓を開く／位置を合わせ直す押し方だったか。
    /// Shift クリックの追加・解除のように、押した時点で選択を変えて `.idle` にする場合に使う。
    var opensPopoverOnRelease = false
    /// ドラッグが閾値を超え、取り消し履歴を積んだか（移動・変形）。
    var hasBegunChange = false
    /// 作成中の注釈。確定する（離す）まで document には入れない。
    /// 途中で小さく戻して離した場合に、取り消し履歴を汚さず捨てられるようにするため。
    var draft: Annotation?
    /// 範囲選択の矩形（注釈座標）。
    var marqueeRect: CGRect?

    var hoverCursor: NSCursor = .arrow

    /// テキスト入力中の状態。重ねた NSTextView と、編集を始めた注釈（新規なら nil）。
    struct TextSession {
        let view: AnnotationTextView
        /// 編集を始めた既存のテキスト注釈。新規なら nil。
        let original: Annotation?
        /// 文字の左上（注釈座標）。
        let origin: CGPoint
    }

    var textSession: TextSession?

    /// 詳しいスタイル設定のポップオーバー（⌘I・右クリック）。
    let stylePopover = StylePopoverController()

    // MARK: 初期化

    init(editor: AnnotationEditor, image: CGImage, pointSize: CGSize) {
        self.editor = editor
        self.pointSize = pointSize
        super.init(frame: NSRect(origin: .zero, size: pointSize))
        focusRingType = .none
        // 下から「元画像（レイヤー）」「注釈・選択枠（描画）」の順に重ねる。
        // 元画像は CALayer の contents に置いて GPU に任せ、マウス操作のたびに
        // 全画素を描き直さない。注釈の描画は `overlay` が受け持つ。
        baseView.frame = bounds
        baseView.autoresizingMask = [.width, .height]
        baseView.setImage(image)
        addSubview(baseView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.canvas = self
        addSubview(overlay)
        editor.transientUIDismisser = { [weak self] in self?.stylePopover.close() }
        editor.canvasFocuser = { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
        // コピー・保存・ツール切り替えの前に、入力途中のテキストを確定できるようにする。
        editor.textEditingFinisher = { [weak self] in self?.commitTextEditing() }
        observeModel()
        // システム設定でアクセントカラーが変わったら、選択枠を描き直す。
        accentObserver = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSColor.systemColorsDidChangeNotification
            ).map({ _ in () }) {
                guard let self else { return }
                self.invalidate()
            }
        }
    }

    /// アクセントカラー変更の監視。キャンバスが解放されたあと、次の通知で自然に終わる。
    private var accentObserver: Task<Void, Never>?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // ライト・ダークの切り替えでも選択枠の色が変わる。
        invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 非アクティブなウィンドウでも最初のクリックから操作できるようにする。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// ドラッグでウィンドウが動かないようにする（透明背景のウィンドウでの保険）。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 矢印キー連打（キーを押し続けた一連）を取り消し 1 回にまとめるための記録。
    /// 最初の 1 回で履歴を積み、そのときの履歴の数を覚える。自動リピート中は
    /// 履歴の数が変わっていなければ履歴を積まずに動かす。
    var nudgeUndoCount: Int?

    /// 表示倍率。
    var viewScale: CGFloat {
        AnnotationInteraction.displayScale(displayWidth: bounds.width, pointWidth: pointSize.width)
    }

    // MARK: モデルの監視

    /// 注釈・選択・ツールが変わったら描き直す。取り消しボタンや将来のポップオーバー
    /// など、キャンバスの外からの変更もここで拾う。
    private func observeModel() {
        withObservationTracking {
            _ = editor.document.annotations
            _ = editor.document.selectedIDs
            _ = editor.tool
        } onChange: { [weak self] in
            // onChange は変更の直前（willSet）に呼ばれるので、値が入ったあとに
            // 描き直せるよう 1 周遅らせる。
            Task { @MainActor in self?.modelDidChange() }
        }
    }

    private func modelDidChange() {
        invalidate()
        // 無くなった注釈（削除・作成ドラッグの破棄・取り消し）のぼかしキャッシュを解放する。
        pruneRedactionCache()
        editor.selectionDidChange()
        // 小窓が開いているときは、選択に合わせて閉じる／位置を合わせ直す
        // （中身は選択を観測しているので自動で変わる）。
        if stylePopover.isShown {
            if document.selectedIDs.isEmpty {
                stylePopover.close()
            } else {
                repositionStylePopover()
            }
        }
        refreshCursor()
        observeModel()
    }

    /// 文書と作成中の注釈に残っているものだけキャッシュに残す。
    func pruneRedactionCache() {
        var ids = Set(document.annotations.map(\.id))
        if let draft { ids.insert(draft.id) }
        editor.redaction.prune(keeping: ids)
    }

    // MARK: 再描画

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 既定では大きさが変わっても描き直されない。表示倍率が変わるので必須。
        invalidate()
        // 表示倍率が変わると、重ねた入力欄の位置・文字サイズも合わせ直す。
        applyTextEditorFont()
        layoutTextEditor()
        // 表示倍率が変わると同じマウス位置でも当たるものが変わるので、カーソルも選び直す。
        refreshCursor()
    }

    // スクロールでもマウス位置の下のものが変わる。親のクリップビューの動きを監視する。
    private var scrollObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCursor() }
        }
    }

    /// Shift の上げ下げで、押したときの動き（追加／解除）が変わるのでカーソルも更新する。
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        refreshCursor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate()
    }

    /// ウィンドウから外れるとき（OCR 開始などでビュー階層が作り直された場合や閉じるとき）に、
    /// 入力途中のテキストを確定し、フォーカス状態とポップオーバーを片付ける。
    /// 残すと `isEditingText` / `isCanvasFocused` が true のまま固まり、Esc が効かなくなる。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            commitTextEditing()
            stylePopover.close()
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
                self.scrollObserver = nil
            }
            editor.isCanvasFocused = false
            editor.isEditingText = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

}
