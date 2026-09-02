import AppKit

// メニューバーの NSStatusItem を管理する。
//
// 要求 4.1 の要点は「クリック＝キャプチャ開始」であること。NSStatusItem に
// menu を代入すると左クリックでもメニューが開いてしまい、この要求を満たせない。
// そのため menu は代入せず、クリック種別を自分で判定して振り分ける。
//
// アイコンのクリックとメニュー項目でコールバックを分けているのは、両者で
// 「キャプチャを始めてよいか」の判断が違うため（CAP-08）。どう違うかは
// 呼び出し側の AppCoordinator が決める。ここは種別を伝えるだけに留める。
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    /// メニュー表示中か。performClick の再入を防ぐ。
    private var isShowingMenu = false

    /// アイコンの左クリック時
    var onCapture: (() -> Void)?
    /// メニューの「範囲を選択してキャプチャ」を選んだとき
    var onCaptureFromMenu: (() -> Void)?
    /// 環境設定を開く
    var onOpenSettings: (() -> Void)?
    /// このアプリについて
    var onShowAbout: (() -> Void)?
    /// 更新を確認する（Sparkle）
    var onCheckForUpdates: (() -> Void)?
    /// 認識モードの変更
    var onSelectMode: ((RecognitionMode) -> Void)?
    /// 現在の認識モード（メニューのチェック表示に使う）
    var currentMode: (() -> RecognitionMode)?
    /// 背面に回った結果ウィンドウを前面に呼び戻す
    var onShowResultWindow: (() -> Void)?
    /// 結果ウィンドウが開いているか（メニュー項目の有効・無効に使う）
    var hasResultWindow: (() -> Bool)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        // 有効・無効は refreshResultWindowItem() で自分で決める。
        // 既定の自動判定のままだと、target/action を持つ項目は表示直前に
        // 強制的に有効へ戻されてしまう。
        menu.autoenablesItems = false

        if let button = statusItem.button {
            button.image = Self.icon(for: .idle)
            button.target = self
            button.action = #selector(handleClick(_:))
            // 右クリックも action に流す（既定では左クリックのみ）。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildMenu()
    }

    // MARK: - アイコンの状態

    /// メニューバーアイコンの状態。
    enum IconState {
        /// 通常。
        case idle
        /// 範囲選択中。キャプチャ中であることが分かるようにする。
        case capturing
    }

    /// キャプチャ中はアイコンを変えて、状態が分かるようにする。
    func setIconState(_ state: IconState) {
        statusItem.button?.image = Self.icon(for: state)
    }

    private static func icon(for state: IconState) -> NSImage? {
        let name: String
        switch state {
        case .idle:
            name = "text.viewfinder"
        case .capturing:
            // 選択中は十字（レティクル）に変えて、いま範囲選択中であることを示す。
            name = "dot.viewfinder"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "JPScreenShot")
        // テンプレート画像にするとダークモード/ライトモードに自動追従する。
        image?.isTemplate = true
        return image
    }

    // MARK: - クリック処理

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // 右クリック、または修飾キーとして Control を押した左クリックはメニュー。
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) ?? false

        if isRightClick || isControlClick {
            showMenu()
        } else {
            onCapture?()
        }
    }

    private func showMenu() {
        // performClick はメニューが閉じるまで同期的にブロックする。
        // その間の再クリックで再入すると、内側の menu = nil が先に走って
        // 状態が壊れる（左クリックでメニューが開く等の散発的な不具合）。
        guard !isShowingMenu else { return }
        isShowingMenu = true
        defer { isShowingMenu = false }

        refreshModeChecks()
        refreshResultWindowItem()
        // menu を代入したままだと左クリックでも開いてしまうため、
        // 表示する瞬間だけ差し込んですぐ外す。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - メニュー構築

    /// 「結果ウィンドウを表示」項目の識別用。有効・無効を更新するために引く。
    private static let showResultWindowTag = 1

    private func buildMenu() {
        menu.removeAllItems()

        let capture = NSMenuItem(
            title: "範囲を選択してキャプチャ",
            action: #selector(menuCapture),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)

        // 背面に回った結果ウィンドウを呼び戻す手段。
        //
        // LSUIElement アプリは Dock アイコンが無く ⌘Tab の対象にもならない。
        // 結果ウィンドウはアプリが非アクティブになると .normal に落ちて他の
        // アプリの下に隠れるため、この項目が唯一の復帰経路になる。
        let showResult = NSMenuItem(
            title: "結果ウィンドウを表示",
            action: #selector(menuShowResultWindow),
            keyEquivalent: ""
        )
        showResult.target = self
        showResult.tag = Self.showResultWindowTag
        menu.addItem(showResult)

        menu.addItem(.separator())

        // 認識モードの切り替え（6.3）
        let modeHeader = NSMenuItem(title: "認識モード", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        for mode in RecognitionMode.allCases {
            let item = NSMenuItem(
                title: "　\(mode.displayName)",
                action: #selector(menuSelectMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "環境設定…",
            action: #selector(menuSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let checkUpdates = NSMenuItem(
            title: "更新を確認…",
            action: #selector(menuCheckForUpdates),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        let about = NSMenuItem(
            title: "JPScreenShot について",
            action: #selector(menuAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "終了",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// 現在の認識モードにチェックを付ける。
    private func refreshModeChecks() {
        let active = currentMode?() ?? .japanese
        for item in menu.items {
            guard let raw = item.representedObject as? String,
                  let mode = RecognitionMode(rawValue: raw)
            else { continue }
            item.state = (mode == active) ? .on : .off
        }
    }

    /// 結果ウィンドウが無いときは「結果ウィンドウを表示」を選べないようにする。
    private func refreshResultWindowItem() {
        guard let item = menu.item(withTag: Self.showResultWindowTag) else { return }
        item.isEnabled = hasResultWindow?() ?? false
    }

    // MARK: - メニュー項目のアクション

    @objc private func menuCapture() {
        onCaptureFromMenu?()
    }

    @objc private func menuShowResultWindow() {
        onShowResultWindow?()
    }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = RecognitionMode(rawValue: raw)
        else { return }
        onSelectMode?(mode)
    }

    @objc private func menuSettings() {
        onOpenSettings?()
    }

    @objc private func menuCheckForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func menuAbout() {
        onShowAbout?()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
