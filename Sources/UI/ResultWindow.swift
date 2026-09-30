import AppKit
import SwiftUI

// 結果ウィンドウ（要求 4.3）。SwiftUI の ResultView を NSWindow に載せる。
//
// メニューバーアプリなので SwiftUI の WindowGroup は使わず、必要なときに
// 自前で NSWindow を作る。
@MainActor
final class ResultWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var model: ResultViewModel?

    /// ウィンドウが閉じられたときの通知（保持を解除してメモリを解放するため）。
    var onClose: (() -> Void)?
    /// 「新規キャプチャ」が押されたときの通知（CAP-09）。
    var onNewCapture: (() -> Void)?

    /// 新規キャプチャのために一時的に隠しているか。
    private var isHiddenForCapture = false

    /// OCR を始めたときに伸ばすテキスト欄の高さ。ResultView の textPane の
    /// idealHeight と揃える。
    private static let textPaneHeight: CGFloat = 180

    func show(capture: CaptureResult) {
        let model = ResultViewModel(capture: capture)
        self.model = model

        let view = ResultView(model: model)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "JPScreenShot"
        // 外周の水色の線（ResultView.windowBorder）をタイトルバーまで
        // 回すため、中身をタイトルバーの下まで広げてタイトルバーを透明にする。
        // 線をテーマフレーム（contentView.superview）に足す方法は AppKit が
        // 「unknown subview」と警告し、将来の OS で壊れうるので使わない。
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 撮影直後は確実に手前に出す。
        //
        // ただし常時 .floating で固定はしない。以前は「LSUIElement なので
        // 沈むと戻す手段が無い」ことを避けて固定していたが、他アプリでの
        // 作業中も居座って邪魔だった。
        //
        // レベルの上げ下げは AppCoordinator がアプリのアクティブ状態に
        // 連動させて setFloating(_:) で行う（環境設定ウィンドウと共通の規則）。
        // ウィンドウ単位の becomeKey/resignKey で切り替えてはいけない。
        // resignKey はアプリ内の別ウィンドウやモーダル（NSAlert・
        // NSOpenPanel）が出ただけでも発火するため、アプリ内のダイアログを
        // 開くたびに沈んでしまう。
        window.level = .floating
        // .fullSizeContentView ではコンテンツ領域がタイトルバーを含むので、
        // タイトルバーの高さを足さないと画像がその分だけ等倍で収まらない。
        var contentSize = Self.initialContentSize(for: capture)
        contentSize.height += window.frame.height - window.contentLayoutRect.height
        window.setContentSize(contentSize)
        window.center()

        model.requestClose = { [weak self] in
            self?.close()
        }
        model.requestNewCapture = { [weak self] in
            self?.onNewCapture?()
        }
        model.onTextPaneOpened = { [weak self] in
            self?.growForTextPane()
        }

        self.window = window

        // メニューバーアプリは通常非アクティブなので、明示的に前面に出す。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // OCR は自動では始めない。「テキストを認識」を押したときに走る（OCR-01）。
    }

    /// 画像の大きさに合わせた初期サイズ。
    ///
    /// 画像が等倍で収まるようにウィンドウを開く。画面より大きい場合は
    /// 画面いっぱいまで広げる（画像自体は等倍のままスクロールで見せる。
    /// 縮小するとリサンプリングでぼやけるため）。
    ///
    /// ★ここは必ずポイントで計算する。`NSWindow.setContentSize` も
    /// `NSScreen.visibleFrame` もポイント系なので、ピクセル数を渡すと
    /// Retina では 2 倍の大きさを要求してしまい、たいていの画像で
    /// 画面幅に張り付いた不自然に大きいウィンドウになる。
    private static func initialContentSize(for capture: CaptureResult) -> NSSize {
        let pointSize = capture.pointSize

        // 縮めたテキスト欄とボタンバーの分を足す。テキスト欄は OCR を
        // 始めたときに growForTextPane() で広げる（OCR-01）。
        let chromeHeight: CGFloat = 90
        // ウィンドウが出る画面の広さで頭打ちにする。撮影元の画面とは限らない
        // （2x の画面で撮って 1x の画面にウィンドウが出ることがある）が、
        // ポイントどうしの比較なので大小関係は正しく、上限として機能する。
        let visible = NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1280, height: 800)

        // 以前は visible.width * 0.8 で上限を掛けていたため、幅の広い
        // キャプチャが強制的に縮小されてぼやけていた。
        // 画面に収まる限りは等倍で見えるようにする。
        // 画像のまわりの余白（ResultView.imageMargin）も足す。
        let margin = ResultView.imageMargin * 2
        let width = min(max(pointSize.width + margin, 480), visible.width)
        let height = min(pointSize.height + margin + chromeHeight, visible.height)
        return NSSize(width: width, height: height)
    }

    func close() {
        window?.close()
    }

    /// テキスト欄を開いた分だけウィンドウを下へ伸ばす（OCR-01）。
    ///
    /// 伸ばさないと VSplitView がいまの高さを画像とテキストで分け合う
    /// ため、見えていた画像が急に狭くなる。上端は動かさず、画面の下端に
    /// 届く場合は上へずらし、それでも足りなければ伸ばせる分だけ伸ばす。
    private func growForTextPane() {
        guard let window, let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        let extra = min(Self.textPaneHeight, max(0, visible.height - frame.height))
        guard extra > 0 else { return }
        frame.size.height += extra
        frame.origin.y -= extra
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - 新規キャプチャ（CAP-09）

    /// 範囲選択の間だけ隠す。撮りたい場所を結果ウィンドウが覆わないようにする。
    ///
    /// 写り込み自体は自アプリのウィンドウをフィルタで除外しているので
    /// 起きないが、隠さないと下にあるものが見えず選べない。
    func hideForCapture() {
        guard let window, window.isVisible else { return }
        isHiddenForCapture = true
        window.orderOut(nil)
    }

    /// キャンセルや失敗で新しい結果が出なかったときに元へ戻す。
    func restoreAfterCapture() {
        guard isHiddenForCapture else { return }
        isHiddenForCapture = false
        bringToFront()
    }

    /// メニューバーからモードが変更されたとき、開いているウィンドウにも反映する。
    /// 認識を始める前なら、モードを選んでおくだけで認識はしない（OCR-01）。
    func applyMode(_ mode: RecognitionMode) {
        model?.mode = mode
    }

    /// 最前面に貼り付けるかどうかを切り替える。
    ///
    /// アプリがアクティブな間だけ true。呼び出しは AppCoordinator が
    /// アプリのアクティブ状態に合わせて行う。
    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    /// 背面に沈んだウィンドウを前面に呼び戻す。
    ///
    /// LSUIElement アプリは Dock アイコンが無く ⌘Tab の対象にもならないため、
    /// いったん他アプリの下に回り込むとユーザーが自力で戻せない。
    /// ステータスメニューの「結果ウィンドウを表示」から呼ぶ。
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // ミニマイズされている場合も戻す。
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// 結果ウィンドウが表示可能な状態にあるか（メニュー項目の有効・無効判定用）。
    var canBringToFront: Bool {
        window != nil
    }

    /// 見失っているなら前面に呼び戻し、呼び戻したことを返す（CAP-08）。
    ///
    /// メニューバーアイコンのクリックは通常キャプチャ開始だが（CAP-01）、
    /// 結果ウィンドウを見失っているときだけは「まず前面に戻す」を優先する。
    /// 見えているなら false を返し、呼び出し側はそのままキャプチャへ進む。
    ///
    /// この判定は「NSStatusBarButton のクリックでは NSApp がアクティブに
    /// ならない」ことに依存している。NSStatusBarWindow はキーにならないため
    /// NSApp.isActive はクリック直前の状態のまま読める。ここが崩れると
    /// 「何度クリックしてもキャプチャが始まらない」詰み方をするので、
    /// 挙動を変えるときは実機で往復を確認すること。
    func bringToFrontIfBackgrounded() -> Bool {
        guard let window else { return false }
        guard Self.shouldBringToFront(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isAppActive: NSApp.isActive,
            isOnActiveSpace: window.isOnActiveSpace
        ) else { return false }

        bringToFront()
        return true
    }

    /// 前面化すべきかの判定。AppKit に触らない純粋関数にしてテストで固定する。
    ///
    /// 原則は「見えているなら前面化しない」。撮った結果を見ながら他アプリを
    /// 操作したあと、アイコンを押した瞬間に次のキャプチャが始まって結果を
    /// 見失うのを防ぐのが目的なので、それ以外では邪魔をしない。
    static func shouldBringToFront(
        isVisible: Bool,
        isMiniaturized: Bool,
        isAppActive: Bool,
        isOnActiveSpace: Bool
    ) -> Bool {
        // 最小化されているなら Dock の中で完全に見えていないので必ず戻す。
        // これから撮りたい画面を隠すこともない。
        if isMiniaturized { return true }
        // 非表示（⌘H で隠した / まだ出していない）。隠したのはユーザーの
        // 意思なので勝手に呼び戻さず、そのままキャプチャへ進ませる。
        guard isVisible else { return false }
        // 別 Space にある場合は前面化しない。NSApp.activate すると Space ごと
        // 切り替わり、いま撮ろうとしている画面から引き剥がしてしまう。
        guard isOnActiveSpace else { return false }
        // アプリがアクティブなら結果ウィンドウは見えている（アクティブな間は
        // .floating で手前に固定される）。環境設定など同じアプリの別ウィンドウ
        // がキーでも見失ってはいないので、isKeyWindow では判定しない。
        return !isAppActive
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 非機能要求（メモリ）: キャプチャ画像は結果ウィンドウを閉じたら解放する。
        // 参照を明示的に切らないと NSWindow 側の保持で CGImage が残る。
        model?.cancelRecognition()
        model?.requestClose = nil
        model?.requestNewCapture = nil
        model?.onTextPaneOpened = nil
        model = nil
        window?.delegate = nil
        // contentViewController は触らない。クローズ処理の途中でビュー階層を
        // 差し替えると AppKit / NSHostingController の内部状態と競合する。
        // model と window の参照を切れば CGImage は連鎖して解放される。
        window = nil
        onClose?()
    }
}
