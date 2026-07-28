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
        window?.contentViewController = nil
        window = nil
        onClose?()
    }
}
