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

    func show(capture: CaptureResult) {
        let model = ResultViewModel(capture: capture)
        self.model = model

        let view = ResultView(model: model)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "JPScreenShot"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
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
        window.setContentSize(Self.initialContentSize(for: capture))
        window.center()

        model.requestClose = { [weak self] in
            self?.close()
        }

        self.window = window

        // メニューバーアプリは通常非アクティブなので、明示的に前面に出す。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // OCR-01: ウィンドウを出した後に自動で認識を開始する。
        // 画像は先に見えているので、OCR の完了は待たせない（4.3）。
        model.recognize()
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

        // テキスト欄とボタンバーの分を足す。
        let chromeHeight: CGFloat = 240
        // ウィンドウが出る画面の広さで頭打ちにする。撮影元の画面とは限らない
        // （2x の画面で撮って 1x の画面にウィンドウが出ることがある）が、
        // ポイントどうしの比較なので大小関係は正しく、上限として機能する。
        let visible = NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1280, height: 800)

        // 以前は visible.width * 0.8 で上限を掛けていたため、幅の広い
        // キャプチャが強制的に縮小されてぼやけていた。
        // 画面に収まる限りは等倍で見えるようにする。
        let width = min(max(pointSize.width, 480), visible.width)
        let height = min(pointSize.height + chromeHeight, visible.height)
        return NSSize(width: width, height: height)
    }

    func close() {
        window?.close()
    }

    /// メニューバーからモードが変更されたとき、開いているウィンドウにも反映する。
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
        model = nil
        window?.delegate = nil
        // contentViewController は触らない。クローズ処理の途中でビュー階層を
        // 差し替えると AppKit / NSHostingController の内部状態と競合する。
        // model と window の参照を切れば CGImage は連鎖して解放される。
        window = nil
        onClose?()
    }
}
