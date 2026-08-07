import AppKit
import SwiftUI

// 環境設定ウィンドウ。
//
// メニューバーアプリなので SwiftUI の Settings シーンは使えず、
// 自前で NSWindow を作る。既に開いていれば前面に出すだけにする。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    /// 閉じられたときの通知（保持を解除するため）。
    var onClose: (() -> Void)?

    func show() {
        // 二重に開かない。開いていれば前面へ。
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "JPScreenShot 環境設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 結果ウィンドウ（.floating）と同じレベルに揃える。
        // .normal のままだと、結果ウィンドウを開いた状態で環境設定を開いても
        // レベルが低いぶん背面に描画され、重なった部分が見えなくなる。
        // 同レベル同士なら通常のキーウィンドウ順序で前後する。
        window.level = .floating
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        // contentViewController は触らない（ResultWindow と同じ理由）。
        window = nil
        onClose?()
    }
}
