import AppKit

// 範囲選択モードの制御（要求 4.2 / CAP-03 / CAP-05）。
//
// すべてのスクリーンにオーバーレイを出し、どの画面でも選択できるようにする。
// どれか 1 つで確定したら全部閉じる。
//
// キャンセル条件（4.2）:
// - Esc キー
// - ドラッグせずクリックしただけ（誤クリック対策）
// - 選択範囲が極端に小さい（8px 未満）
@MainActor
final class SelectionCoordinator {

    /// 選択範囲が有効と見なす最小の辺の長さ（ピクセル）。要求 4.2。
    ///
    /// 寸法ラベルもピクセル表示なので、判定と表示の単位を揃える。
    /// ポイントで判定すると Retina で実質 16px 相当になり、
    /// 「16 × 16 と表示されている選択が通り 14 × 14 は弾かれる」という
    /// 見た目と挙動の非対称が生じる。
    private static let minimumSideLengthInPixels: CGFloat = 8

    private var windows: [OverlayWindow] = []
    private var keyMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?

    /// ドラッグ開始点（AppKit のグローバル座標）。
    private var anchorPoint: CGPoint?
    /// 実際にドラッグされたか（クリックのみのキャンセル判定用）。
    private var didDrag = false

    private var completion: ((CGRect?) -> Void)?

    /// 範囲選択を開始する。
    /// - Parameter completion: 確定した矩形（AppKit グローバル座標）。
    ///   キャンセル時は nil。
    func begin(completion: @escaping (CGRect?) -> Void) {
        // 二重起動を防ぐ。
        guard windows.isEmpty else { return }

        self.completion = completion
        anchorPoint = nil
        didDrag = false

        // すべてのスクリーンにオーバーレイを出す（CAP-03）。
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            attachHandlers(to: window)
            window.orderFrontRegardless()
            windows.append(window)
        }

        // キーウィンドウを 1 つ作ってキー入力を受け取れるようにする。
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        observeScreenChanges()
    }

    // MARK: - イベント処理

    /// マウス操作は各オーバーレイビューから受け取る。
    ///
    /// ローカルモニタは自アプリがアクティブであることを前提とするため、
    /// activate 直後の数十 ms のクリックを取り逃す危険がある。ビューで
    /// 受ければ確実に届く。
    private func attachHandlers(to window: OverlayWindow) {
        let view = window.overlayView
        view.onMouseDown = { [weak self] point in
            guard let self else { return }
            self.anchorPoint = point
            self.didDrag = false
            self.updateSelection(to: point)
        }
        view.onMouseDragged = { [weak self] point in
            guard let self, self.anchorPoint != nil else { return }
            self.didDrag = true
            self.updateSelection(to: point)
        }
        view.onMouseUp = { [weak self] point in
            guard let self else { return }
            self.handleMouseUp(at: point)
        }
    }

    private func handleMouseUp(at point: CGPoint) {
        guard let anchor = anchorPoint else {
            // mouseDown を取り逃していた場合。無反応にせずキャンセルする。
            finish(with: nil)
            return
        }
        let rect = Self.rect(from: anchor, to: point)

        // ドラッグしていない（クリックのみ）はキャンセル（4.2 誤クリック対策）。
        guard didDrag else {
            finish(with: nil)
            return
        }
        // 極端に小さい選択もキャンセル（4.2）。ピクセル基準で判定する。
        let scale = ScreenGeometry.screen(containing: rect)?.backingScaleFactor ?? 1
        guard rect.width * scale >= Self.minimumSideLengthInPixels,
              rect.height * scale >= Self.minimumSideLengthInPixels
        else {
            finish(with: nil)
            return
        }
        finish(with: rect)
    }

    /// キー入力は Esc のキャンセルだけを拾う（CAP-05）。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Cmd 付きは通す。全画面暗転中に Cmd+Q すら効かない状態を作らない。
            if event.modifierFlags.contains(.command) {
                // Cmd+. はキャンセルの慣習なので拾う。
                if event.charactersIgnoringModifiers == "." {
                    self.finish(with: nil)
                    return nil
                }
                return event
            }
            // keyCode 53 が Esc。
            if event.keyCode == 53 {
                self.finish(with: nil)
                return nil
            }
            // その他のキーはオーバーレイ中は無視する。
            return nil
        }
    }

    /// 選択中のディスプレイ構成変更に備える。
    ///
    /// 画面が抜き差しされたり配置が変わると windows が古い frame のまま残り、
    /// 覆いのない画面ができて座標も破綻する。安全側に倒してキャンセルする。
    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(with: nil)
            }
        }
    }

    /// 選択中の矩形を各オーバーレイに反映する。
    private func updateSelection(to current: CGPoint) {
        guard let anchor = anchorPoint else { return }
        let globalRect = Self.rect(from: anchor, to: current)

        for window in windows {
            // グローバル座標 → そのウィンドウのローカル座標へ。
            let frame = window.frame
            let local = CGRect(
                x: globalRect.origin.x - frame.origin.x,
                y: globalRect.origin.y - frame.origin.y,
                width: globalRect.width,
                height: globalRect.height
            )
            window.overlayView.selectionRect = local
        }
    }

    /// 2 点から正規化した矩形を作る（どの方向にドラッグしても正の幅・高さ）。
    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - 終了処理

    private func finish(with rect: CGRect?) {
        let handler = completion
        completion = nil
        anchorPoint = nil

        // 実装計画 6.2: オーバーレイは「キャプチャ前に確実に閉じる」。
        // excludingWindows だけに頼らず、写り込みの可能性を物理的に消す。
        teardown()

        handler?(rect)
    }

    private func teardown() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        for window in windows {
            // ハンドラがビュー経由で self を掴んでいるので明示的に切る。
            window.overlayView.onMouseDown = nil
            window.overlayView.onMouseDragged = nil
            window.overlayView.onMouseUp = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
