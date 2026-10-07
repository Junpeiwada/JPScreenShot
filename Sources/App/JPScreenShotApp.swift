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
        #if DEBUG
        coordinator?.openDebugImageIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q 直前のスタイル変更が、保存のデバウンスを待たずに失われないようにする。
        coordinator?.flushAnnotationStyles()
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

        // 設定（⌘,）。ステータスメニュー側にも同じ項目があるが、
        // そちらは NSStatusItem に紐づくメニューなので Key Equivalent の
        // 走査対象にならず、⌘, と表示されるだけで実際には効かない。
        // 押せるようにするにはメインメニューにも置く必要がある。
        let settings = menu.addItem(
            withTitle: "設定…",
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

        // ⌘Q は確認を挟む（QuitConfirmation）。terminate(_:) を直接呼ばない。
        let quit = menu.addItem(
            withTitle: "\(name) を終了",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quit.target = self

        return menu
    }

    /// メインメニューの「終了」（⌘Q）。
    @objc private func quitFromMenu() {
        QuitConfirmation.confirmAndTerminate()
    }

    /// メインメニューの「設定…」（⌘,）。
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
        // 注釈の複製。キャンバスが First Responder のときだけ有効（⌘D）。
        menu.addItem(
            withTitle: "複製",
            action: NSSelectorFromString("duplicate:"),
            keyEquivalent: "d"
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

// 終了前の確認。
//
// ⌘Q の押し間違いで常駐が消えると、気づかないままキャプチャできなくなる。
// 確認はユーザーの終了操作（⌘Q・ステータスメニューの「終了」）にだけ挟む。
// applicationShouldTerminate で止めないのは、Sparkle の更新による再起動や
// ログアウト・再起動に伴う終了まで止めてしまうため。
@MainActor
enum QuitConfirmation {
    /// ダイアログ表示中か。表示中に ⌘Q を押しても二重に出さない。
    private static var isShowing = false

    static func confirmAndTerminate() {
        guard !isShowing else { return }
        isShowing = true
        defer { isShowing = false }

        // LSUIElement アプリは非アクティブのことが多く、そのままだと
        // ダイアログが他アプリの下に出る。
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "JPScreenShot を終了しますか？"
        alert.informativeText = "終了するとメニューバーのアイコンが消え、キャプチャできなくなります。"
        alert.addButton(withTitle: "終了")
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }
}
