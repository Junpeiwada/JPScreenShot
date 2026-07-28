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

    func show(image: CGImage) {
        let model = ResultViewModel(image: image)
        self.model = model

        let view = ResultView(model: model)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "JPScreenShot"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.initialContentSize(for: image))
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
    private static func initialContentSize(for image: CGImage) -> NSSize {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)

        // テキスト欄とボタンバーの分を足す。
        let chromeHeight: CGFloat = 240
        let visible = NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1280, height: 800)

        // 以前は visible.width * 0.8 で上限を掛けていたため、幅 2048px を
        // 超えるキャプチャが強制的に縮小されてぼやけていた。
        // 画面に収まる限りは等倍で見えるようにする。
        let width = min(max(imageWidth, 480), visible.width)
        let height = min(imageHeight + chromeHeight, visible.height)
        return NSSize(width: width, height: height)
    }

    func close() {
        window?.close()
    }

    /// メニューバーからモードが変更されたとき、開いているウィンドウにも反映する。
    func applyMode(_ mode: RecognitionMode) {
        model?.mode = mode
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 非機能要求（メモリ）: キャプチャ画像は結果ウィンドウを閉じたら解放する。
        // 参照を明示的に切らないと NSWindow 側の保持で CGImage が残る。
        model?.cancelRecognition()
        model?.requestClose = nil
        model = nil
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
        onClose?()
    }
}
