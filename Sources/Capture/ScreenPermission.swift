import AppKit
import CoreGraphics

// 画面収録権限の確認と誘導。
//
// 要求 7 / 受け入れ基準 10: 権限が無い場合は「黙って何も起きない状態にしない」。
// システム設定の該当画面へ誘導する案内を出す。
//
// 実装計画 1.3 のとおり、この権限は署名されたアプリバンドルの識別情報に紐づく。
// ad-hoc 署名では署名が変わるたびに許可が失われるため、開発中に
// 「昨日は動いたのに拒否される」が起きうる。その場合はシステム設定で
// 一度チェックを外して入れ直す必要がある。
@MainActor
enum ScreenPermission {

    /// 許可ダイアログを出さずに現在の状態を確認する。
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// キャプチャ前に権限を確保する。
    /// - Returns: 続行してよいなら true。案内を出して中断したなら false。
    static func ensure() -> Bool {
        if isGranted { return true }

        // 未許可の場合、まず OS に要求する。初回はここでシステムのダイアログが出る。
        // 2 回目以降は false が返るだけでダイアログは出ない（OS の仕様）。
        if CGRequestScreenCaptureAccess() {
            return true
        }

        presentGuidance()
        return false
    }

    /// システム設定へ誘導する案内を表示する（基準 10）。
    private static func presentGuidance() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "画面収録の権限が必要です"
        alert.informativeText = """
            JPScreenShot が画面をキャプチャするには、システム設定で
            「画面収録とシステムオーディオ録音」の許可が必要です。

            システム設定を開き、一覧の JPScreenShot をオンにしてください。
            すでにオンの場合は、一度オフにしてから再度オンにすると
            認識されることがあります。
            """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "キャンセル")

        // 案内は最前面に出す。メニューバーアプリは通常非アクティブなため。
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// システム設定の「画面収録」ペインを直接開く。
    private static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
