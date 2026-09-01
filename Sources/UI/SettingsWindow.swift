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
        // 結果ウィンドウと同じレベルに揃える。
        // レベルが違うと、片方が常にもう片方の背面に描画されて重なった部分が
        // 見えなくなる。同レベル同士なら通常のキーウィンドウ順序で前後する。
        //
        // 上げ下げは AppCoordinator がアプリのアクティブ状態に連動させて
        // setFloating(_:) で行う。ここで .floating に固定してしまうと、
        // 他アプリに切り替えても環境設定だけ最前面に居座り続ける。
        window.level = .floating
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// 最前面に貼り付けるかどうかを切り替える（ResultWindow と共通の規則）。
    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        // contentViewController は触らない（ResultWindow と同じ理由）。
        window = nil
        onClose?()
    }
}
