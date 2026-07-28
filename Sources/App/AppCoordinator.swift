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
        preloadedContent = nil
        preloadTask = Task { @MainActor in
            self.preloadedContent = try? await ScreenCaptureService.fetchShareableContent()
        }

        let coordinator = SelectionCoordinator()
        selection = coordinator
        coordinator.begin { [weak self] rect in
            guard let self else { return }
            self.selection = nil
            guard let rect else {
                // キャンセル（CAP-05）。先読みも破棄する。
                self.discardPreload()
                return
            }
            self.performCapture(rect: rect)
        }
    }

    private func discardPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedContent = nil
    }

    private func performCapture(rect: CGRect) {
        Task { @MainActor in
            defer { self.discardPreload() }
            do {
                // 先読みの完了を待つ。結果は preloadedContent に入る。
                // 失敗していた場合は nil のまま capture 側で取り直す。
                await self.preloadTask?.value
                let image = try await ScreenCaptureService.capture(
                    appKitRect: rect,
                    content: self.preloadedContent
                )
                // 段階 4 で結果ウィンドウに差し替える。現時点では取得できた
                // ことを確認できるようにプレビューで開く。
                previewForVerification(image)
            } catch {
                presentError(error)
            }
        }
    }

    /// 段階 3 の確認用。CAP-04（オーバーレイが写り込まない）を目視するため
    /// 一時ファイルに書き出して開く。段階 4 で結果ウィンドウに置き換える。
    private func previewForVerification(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        // UUID で衝突を避ける（同一秒の連続キャプチャでも上書きしない）。
        let url = FileManager.default.temporaryDirectory
            .appending(path: "JPScreenShot_capture_\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            presentError(error)
        }
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
