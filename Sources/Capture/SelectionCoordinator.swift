import AppKit
import ScreenCaptureKit

// 範囲選択モードの制御（要求 4.2 / CAP-03 / CAP-05 / CAP-06）。
//
// すべてのスクリーンにオーバーレイを出し、どの画面でも選択できるようにする。
// どれか 1 つで確定したら全部閉じる。
//
// 操作の割り当て:
// - ドラッグ → その矩形をキャプチャ
// - クリック（ドラッグなし）→ その位置のウィンドウをキャプチャ（CAP-06）
//
// キャンセル条件（4.2）:
// - Esc キー
// - クリックした位置にウィンドウがない（デスクトップなど）
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

    private var completion: ((CaptureTarget?) -> Void)?

    /// 重なり順を解決したウィンドウ候補（CAP-06）。
    ///
    /// AppCoordinator が先読みした共有可能コンテンツから作る。ここで取り直すと
    /// クリックのたびに数百 ms 待たされる。先読みが間に合っていない場合は
    /// nil のままで、ウィンドウのハイライトと確定が単に無効になる。
    ///
    /// 一度作ったら選択が終わるまで使い回す。オーバーレイを出している間は
    /// 他アプリのウィンドウが前後しないため、カーソルが動くたびに重なり順を
    /// 取り直す必要がない。
    private var candidates: WindowPicker.Candidates?

    /// 現在ハイライトしているウィンドウ。クリック時にこれを確定する。
    ///
    /// mouseUp の時点で引き直すのではなくホバーの結果を使うのは、
    /// 「見えているハイライトと撮れるものを必ず一致させる」ため。
    private var hoveredWindow: WindowPicker.Hovered?

    /// 範囲選択を開始する。
    /// - Parameters:
    ///   - content: ウィンドウ選択に使う共有可能コンテンツ（CAP-06）。
    ///     nil の場合、クリックによるウィンドウ選択は無効になる。
    ///   - completion: 確定した対象。キャンセル時は nil。
    func begin(
        content: SCShareableContent?,
        completion: @escaping (CaptureTarget?) -> Void
    ) {
        // 二重起動を防ぐ。
        guard windows.isEmpty else { return }

        self.completion = completion
        anchorPoint = nil
        didDrag = false
        hoveredWindow = nil

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
        // 候補はオーバーレイを出したあとに作る。自アプリのどのウィンドウが
        // オーバーレイなのかは、生成後でないと windowNumber で識別できない。
        candidates = makeCandidates(from: content)
        // 初期位置のウィンドウをハイライトしておく。オーバーレイが出た直後は
        // マウスが動いていないため mouseMoved が来ず、動かすまで
        // 「クリックで撮れる」ことに気づけない。
        updateHoveredWindow(at: NSEvent.mouseLocation)
    }

    /// 先読みした共有可能コンテンツを後から渡す（CAP-06）。
    ///
    /// SCShareableContent の取得には時間がかかるため、AppCoordinator は
    /// オーバーレイ表示と並行して取得する（実装計画 6.4）。begin の時点では
    /// まだ nil なので、完了したらここで注入してハイライトを有効にする。
    /// 選択が既に終わっていた場合（windows が空）は何もしない。
    func updateShareableContent(_ content: SCShareableContent?) {
        guard !windows.isEmpty else { return }
        candidates = makeCandidates(from: content)
        // ドラッグ中に届いた場合はハイライトを出さない。範囲選択に入った
        // 時点で消してあるものを、先読みの完了で勝手に戻さない。
        guard anchorPoint == nil else { return }
        // 注入時点のカーソル位置で即座にハイライトを出す。次に動かすまで
        // 反映されないと、素早くクリックしたときに何も撮れない。
        updateHoveredWindow(at: NSEvent.mouseLocation)
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
            // 範囲選択に入ったらウィンドウのハイライトは消す。両方出したままだと
            // どちらが撮れるのか分からなくなる。
            self.clearHoveredWindow()
            self.updateSelection(to: point)
        }
        view.onMouseUp = { [weak self] point in
            guard let self else { return }
            self.handleMouseUp(at: point)
        }
        view.onMouseMoved = { [weak self] point in
            guard let self, self.anchorPoint == nil else { return }
            self.updateHoveredWindow(at: point)
        }
    }

    private func handleMouseUp(at point: CGPoint) {
        guard let anchor = anchorPoint else {
            // mouseDown を取り逃していた場合。無反応にせずキャンセルする。
            finish(with: nil)
            return
        }

        // ドラッグしていない（クリックのみ）→ ウィンドウキャプチャ（CAP-06）。
        //
        // 従来はここを誤クリック対策のキャンセルにしていたが、ユーザー要求で
        // ウィンドウ選択に割り当てた。クリック位置にウィンドウがない場合は
        // 従来どおりキャンセルするので、誤クリックの逃げ道は残っている。
        guard didDrag else {
            if let hoveredWindow {
                finish(with: .window(hoveredWindow.window))
            } else {
                finish(with: nil)
            }
            return
        }

        let rect = Self.rect(from: anchor, to: point)
        // 極端に小さい選択はキャンセル（4.2）。ピクセル基準で判定する。
        //
        // ここをウィンドウキャプチャに転用はしない。わずかに動いた場合は
        // 「ウィンドウを撮ろうとして手が震えた」とも「小さすぎる範囲を
        // 選んだ」とも解釈できるが、誤って意図しないウィンドウを撮るより
        // 何もしない方が害が小さい。
        let scale = ScreenGeometry.screen(containing: rect)?.backingScaleFactor ?? 1
        guard rect.width * scale >= Self.minimumSideLengthInPixels,
              rect.height * scale >= Self.minimumSideLengthInPixels
        else {
            finish(with: nil)
            return
        }
        finish(with: .region(rect))
    }

    // MARK: - ウィンドウのハイライト（CAP-06）

    /// 重なり順を解決した候補一覧を作る。
    ///
    /// 自アプリのウィンドウのうちオーバーレイ以外（結果ウィンドウ・環境設定
    /// ウィンドウ）は、キャプチャ対象にはならないが他アプリのウィンドウを
    /// 実際に覆い隠している。遮蔽物として渡さないと、結果ウィンドウの陰に
    /// いて見えていないウィンドウを選べてしまう。
    ///
    /// オーバーレイ自身は渡さない。全画面を覆っているため、遮蔽物に数えると
    /// 画面上のすべてが隠れていることになり、何も選べなくなる。
    private func makeCandidates(from content: SCShareableContent?) -> WindowPicker.Candidates? {
        guard let content else { return nil }
        let overlayNumbers = Set(windows.map(\.windowNumber))
        let ownWindows = NSApp.windows
            .filter { $0.isVisible && !overlayNumbers.contains($0.windowNumber) }
            // SCWindow.frame と揃えるため CoreGraphics 座標に直す。
            .map { ScreenGeometry.convertToCoreGraphics($0.frame) }
        return WindowPicker.candidates(from: content, foregroundOccluders: ownWindows)
    }

    /// カーソル下のウィンドウを引き直し、全オーバーレイに反映する。
    private func updateHoveredWindow(at point: CGPoint) {
        guard let candidates else {
            clearHoveredWindow()
            return
        }
        guard let hit = WindowPicker.hitTest(at: point, in: candidates) else {
            clearHoveredWindow()
            return
        }
        // 同じウィンドウなら描画し直さない（windowID で比較する。
        // SCWindow のインスタンスは content を取り直すと別物になる）。
        // 重なり順は選択中に変わらないので、可視領域も描き直す必要はない。
        guard hit.window.windowID != hoveredWindow?.window.windowID else { return }
        hoveredWindow = hit

        // SCWindow.frame と可視領域は CoreGraphics 座標なので AppKit 座標に
        // 直してから、各オーバーレイのローカル座標へ落とす。
        let globalFrame = ScreenGeometry.convertToAppKit(hit.window.frame)
        let globalVisible = hit.visibleRects.map(ScreenGeometry.convertToAppKit)

        // ラベルを出すオーバーレイを 1 枚だけ決める。画面をまたぐウィンドウで
        // 同じ名前が両画面に出ると、2 つ選ばれているように見えてしまう。
        // 最も広く見えている画面に出すのが、目が向いている先に近い。
        let labeled = windows.max { a, b in
            visibleArea(of: globalVisible, on: a) < visibleArea(of: globalVisible, on: b)
        }

        for overlay in windows {
            let origin = overlay.frame.origin
            overlay.overlayView.hoveredWindow = OverlayView.WindowHighlight(
                frame: globalFrame.offsetBy(dx: -origin.x, dy: -origin.y),
                visibleRects: globalVisible.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
                label: overlay === labeled ? hit.label : ""
            )
        }
    }

    /// そのオーバーレイの上で可視領域が占める面積（AppKit グローバル座標）。
    private func visibleArea(of rects: [CGRect], on overlay: OverlayWindow) -> CGFloat {
        rects.reduce(0) { total, rect in
            let clipped = rect.intersection(overlay.frame)
            guard !clipped.isNull, !clipped.isEmpty else { return total }
            return total + clipped.width * clipped.height
        }
    }

    private func clearHoveredWindow() {
        hoveredWindow = nil
        for overlay in windows {
            overlay.overlayView.hoveredWindow = nil
        }
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
    ///
    /// マウス座標は小数を含む。小数のまま矩形を作るとキャプチャ時に
    /// サブピクセル位置から取得され、補間でぼやける（実測で鮮明度が
    /// 7.629 → 5.132 に低下）。ここで整数に丸め、選択枠の表示と
    /// 実際に撮れるピクセルを一致させる。
    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let minX = min(a.x, b.x).rounded()
        let minY = min(a.y, b.y).rounded()
        let maxX = max(a.x, b.x).rounded()
        let maxY = max(a.y, b.y).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 終了処理

    private func finish(with target: CaptureTarget?) {
        let handler = completion
        completion = nil
        anchorPoint = nil
        hoveredWindow = nil
        candidates = nil

        // 実装計画 6.2: オーバーレイは「キャプチャ前に確実に閉じる」。
        // excludingWindows だけに頼らず、写り込みの可能性を物理的に消す。
        teardown()

        handler?(target)
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
            window.overlayView.onMouseMoved = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
