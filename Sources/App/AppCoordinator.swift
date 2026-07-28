import AppKit

// キャプチャ → OCR → 結果表示 の全体制御。
//
// 実装計画 4.1 の流れをここに集約する。段階 1 の時点ではメニューバー常駐まで
// を担い、キャプチャ以降は段階 2/3 で実装する。
@MainActor
final class AppCoordinator {
    private let menuBar = MenuBarController()
    private let settings = Settings.shared

    init() {
        menuBar.onCapture = { [weak self] in
            self?.beginCapture()
        }
        menuBar.currentMode = { [weak self] in
            self?.settings.recognitionMode ?? .japanese
        }
        menuBar.onSelectMode = { [weak self] mode in
            self?.settings.recognitionMode = mode
        }
        menuBar.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        menuBar.onShowAbout = { [weak self] in
            self?.showAbout()
        }
    }

    // MARK: - キャプチャ

    private func beginCapture() {
        // 段階 3 で SelectionCoordinator に置き換える。
        // ここで黙って何もしないと「壊れている」と区別できないため、
        // 未実装であることを明示する。
        let alert = NSAlert()
        alert.messageText = "キャプチャは未実装です"
        alert.informativeText = """
            段階 1（メニューバー常駐）まで実装済みです。
            範囲選択とキャプチャは段階 3 で実装します。

            現在の認識モード: \(settings.recognitionMode.displayName)
            """
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - その他のメニュー項目

    private func openSettings() {
        // 段階 7 で SettingsView に置き換える。
        let alert = NSAlert()
        alert.messageText = "環境設定は未実装です"
        alert.informativeText = "段階 7 で実装します。"
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "JPScreenShot \(version)"
        alert.informativeText = """
            画面の範囲をキャプチャし、画像と OCR テキストの
            どちらでもコピーできるようにするアプリです。

            OCR はオンデバイスで処理され、画像は外部に送信されません。
            """
        alert.alertStyle = .informational
        alert.runModal()
    }
}
