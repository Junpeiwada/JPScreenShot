import AppKit

// メニューバー常駐アプリのエントリポイント。
// SwiftUI の App ではなく NSApplicationDelegate を使う。結果ウィンドウは
// SwiftUI で作るが、アプリ自体は NSStatusItem とオーバーレイウィンドウという
// AppKit 主体の構成であり、ウィンドウを持たない常駐形態と相性が良い。
@main
enum JPScreenShotApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement を Info.plist で指定済みだが、明示しておく。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // メニュー項目のアクションが coordinator を呼ぶため、先に用意する。
        coordinator = AppCoordinator()
        installMainMenu()
    }

    // MARK: - メインメニュー

    /// アプリのメインメニューを組み立てる。
    ///
    /// LSUIElement なので画面上のメニューバーには一切表示されないが、
    /// **これが無いと ⌘C などの標準ショートカットが効かない**。
    /// macOS のキーイベントは、まず NSApp.mainMenu の Key Equivalent を
    /// 走査し、そこで見つかった項目のアクション（copy: など）を
    /// First Responder に送る、という経路をたどる。メインメニューが
    /// 空だと ⌘C はどこにもマッチせず捨てられ、結果ウィンドウの
    /// TextEditor で選択部分をコピーできなくなる（4.3）。
    ///
    /// NSStatusItem のメニュー（MenuBarController）はステータス項目に
    /// 紐づく別物で、この走査の対象にはならない。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // アプリ名メニュー。表示はされないが、先頭にアプリメニューを置くのが
        // AppKit の想定する構造。⌘,・⌘H・⌘Q をここで有効にする。
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        appItem.submenu = makeAppMenu()

        // 編集メニュー。⌘C を成立させるのが主目的。
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        editItem.submenu = makeEditMenu()

        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenu() -> NSMenu {
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "JPScreenShot"
        let menu = NSMenu(title: name)

        // 環境設定（⌘,）。ステータスメニュー側にも同じ項目があるが、
        // そちらは NSStatusItem に紐づくメニューなので Key Equivalent の
        // 走査対象にならず、⌘, と表示されるだけで実際には効かない。
        // 押せるようにするにはメインメニューにも置く必要がある。
        let settings = menu.addItem(
            withTitle: "環境設定…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = self

        menu.addItem(.separator())

        // 以下は target を nil のままにする。nil-target のアクションは
        // レスポンダチェーンの終端にいる NSApplication まで到達し、
        // その既定実装が拾う。
        menu.addItem(
            withTitle: "\(name) を隠す",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthers = menu.addItem(
            withTitle: "ほかを隠す",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "\(name) を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    /// メインメニューの「環境設定…」（⌘,）。
    @objc private func openSettingsFromMenu() {
        coordinator?.openSettings()
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "編集")

        // いずれも target は nil のまま。First Responder（NSTextView など）が
        // 応答できるときだけ自動で有効になる。
        menu.addItem(
            withTitle: "取り消す",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )

        let redo = menu.addItem(
            withTitle: "やり直す",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "カット",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "コピー",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "ペースト",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: "削除",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "すべてを選択",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        return menu
    }

    // メニューバーアプリなので、ウィンドウを全部閉じても終了しない。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
