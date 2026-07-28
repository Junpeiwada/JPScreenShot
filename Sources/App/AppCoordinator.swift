import AppKit
import ScreenCaptureKit

// キャプチャ → OCR → 結果表示 の全体制御。
//
// 実装計画 4.1 の流れをここに集約する。段階 1 の時点ではメニューバー常駐まで
// を担い、キャプチャ以降は段階 2/3 で実装する。
@MainActor
final class AppCoordinator {
    private let menuBar = MenuBarController()
    private let settings = Settings.shared
    /// 範囲選択中のみ保持する。多重起動の判定も兼ねる。
    private var selection: SelectionCoordinator?
    // SCShareableContent の先読み（実装計画 6.4）。
    //
    // SCShareableContent は非 Sendable であり、Task の結果型にすると
    // アクター境界を越えられずコンパイルできない（実装計画 6.5）。
    // そのため「結果は MainActor 隔離のプロパティに格納し、Task 自体は
    // Void を返す」形にして境界を越えさせない。
    private var preloadedContent: SCShareableContent?
    private var preloadTask: Task<Void, Never>?
    /// 結果ウィンドウ。閉じたら nil にして画像を解放する。
    private var resultWindow: ResultWindow?
    /// 環境設定ウィンドウ。開いている間だけ保持する。
    private var settingsWindow: SettingsWindow?
    /// アプリ内自動更新。生成時点で定期確認が動き出すため保持し続ける。
    private let updater = UpdaterController()

    init() {
        menuBar.onCapture = { [weak self] in
            self?.beginCapture()
        }
        menuBar.currentMode = { [weak self] in
            self?.settings.recognitionMode ?? .japanese
        }
        menuBar.onSelectMode = { [weak self] mode in
            self?.settings.recognitionMode = mode
            // 結果ウィンドウが開いていれば、そちらも即座に再認識する（6.3）。
            self?.resultWindow?.applyMode(mode)
        }
        menuBar.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        menuBar.onShowAbout = { [weak self] in
            self?.showAbout()
        }
        menuBar.onCheckForUpdates = { [weak self] in
            self?.updater.checkForUpdates()
        }
    }

    // MARK: - キャプチャ

    private func beginCapture() {
        // 多重起動を防ぐ。
        guard selection == nil else { return }

        // ステータス項目のアクション実行中に同期モーダルを回すと
        // ハイライトが残る等の不具合が出るため、次のループに逃がす。
        Task { @MainActor in
            // 段階 2: 権限が無ければ案内を出して中断する（基準 10）。
            guard ScreenPermission.ensure() else { return }
            self.startSelection()
        }
    }

    private func startSelection() {
        guard selection == nil else { return }

        // 実装計画 6.4: SCShareableContent の取得は時間がかかるため、
        // オーバーレイ表示と同時に先読みし、ドラッグ中に完了させる。
        // 範囲選択中はアイコンを変えて状態を示す。
        menuBar.setIconState(.capturing)

        let coordinator = SelectionCoordinator()
        selection = coordinator

        preloadedContent = nil
        preloadTask = Task { @MainActor in
            let content = try? await ScreenCaptureService.fetchShareableContent()
            self.preloadedContent = content
            // CAP-06: クリックによるウィンドウ選択は content が必要なので、
            // 取得できた時点で選択中のコーディネータに渡す。begin の時点では
            // まだ取得が終わっていない。
            coordinator.updateShareableContent(content)
        }

        coordinator.begin(content: preloadedContent) { [weak self] target in
            guard let self else { return }
            self.selection = nil
            self.menuBar.setIconState(.idle)
            guard let target else {
                // キャンセル（CAP-05）。先読みも破棄する。
                self.discardPreload()
                return
            }
            self.performCapture(target: target)
        }
    }

    private func discardPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedContent = nil
    }

    private func performCapture(target: CaptureTarget) {
        Task { @MainActor in
            defer { self.discardPreload() }
            do {
                let image: CGImage
                switch target {
                case .region(let rect):
                    // 先読みの完了を待つ。結果は preloadedContent に入る。
                    // 失敗していた場合は nil のまま capture 側で取り直す。
                    await self.preloadTask?.value
                    image = try await ScreenCaptureService.capture(
                        appKitRect: rect,
                        content: self.preloadedContent
                    )
                case .window(let window):
                    // CAP-06: ウィンドウ単位のキャプチャ。フィルタが対象を
                    // 直接指すので content の待ち合わせは不要
                    // （そもそも content がなければ window は選ばれない）。
                    image = try await ScreenCaptureService.capture(
                        window: window,
                        includeShadow: self.settings.includeWindowShadow
                    )
                }
                showResult(image)
            } catch {
                presentError(error)
            }
        }
    }

    /// 結果ウィンドウを表示する（要求 4.3）。
    ///
    /// 一時ファイルに書き出してプレビュー.app で開く方式はやめた。
    /// プレビューはウィンドウに合わせて画像を拡大するため 1x の
    /// スクリーンショットがぼやけて見え、要求 4.3 の「等倍より大きく
    /// 拡大はしない」に反する。自前のウィンドウなら等倍で出せる。
    private func showResult(_ image: CGImage) {
        // 前のウィンドウを必ず閉じてから開く。
        //
        // NSWindow.delegate は weak なので、resultWindow を上書きすると
        // ResultWindow を強参照する者がいなくなって即座に解放される。
        // すると windowWillClose が呼ばれず、ユーザーが 1 枚目を閉じても
        // CGImage が解放されないままウィンドウだけ画面に残る
        // （isReleasedWhenClosed = false のため NSWindow も残る）。
        resultWindow?.close()
        resultWindow = nil

        let window = ResultWindow()
        resultWindow = window
        window.onClose = { [weak self, weak window] in
            // 画像を解放するため参照を切る（非機能要求・メモリ）。
            // 別のウィンドウに差し替わっている場合は消さない。
            guard let self, self.resultWindow === window else { return }
            self.resultWindow = nil
        }
        window.show(image: image)
    }

    private func presentError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "キャプチャできませんでした"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - その他のメニュー項目

    private func openSettings() {
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        window.onClose = { [weak self] in
            self?.settingsWindow = nil
        }
        window.show()
    }

    private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let alert = NSAlert()
        alert.messageText = "JPScreenShot \(version) (\(build))"
        alert.informativeText = """
            画面の範囲をキャプチャし、画像と OCR テキストの
            どちらでもコピーできるようにするアプリです。

            使い方:
            ・メニューバーのアイコンをクリックすると選択が始まります
            ・ドラッグで範囲をキャプチャ
            ・ウィンドウをクリックするとそのウィンドウをキャプチャ
            ・右クリックでメニュー（認識モードの切替・環境設定）
            ・Esc で選択をキャンセルできます

            プライバシー:
            OCR は Vision framework によるオンデバイス処理です。
            画像もテキストも外部に送信しません。キャプチャ画像は
            「保存」を押したときだけディスクに書き込まれます。
            """
        alert.alertStyle = .informational
        alert.runModal()
    }
}
