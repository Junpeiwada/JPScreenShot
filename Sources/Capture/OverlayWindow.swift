import AppKit

// 範囲選択用のオーバーレイウィンドウ。1 スクリーンにつき 1 つ作る。
//
// 実装計画 6.3 の注意点に対応する:
// - borderless な NSWindow は既定でキーウィンドウになれないため
//   canBecomeKey を上書きして Esc やマウスイベントを受け取れるようにする
// - level を screenSaver 相当にして最前面（Dock やメニューバーより上）に出す
final class OverlayWindow: NSWindow {

    let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView()
        overlayView.backingScale = screen.backingScaleFactor

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // 最前面に出す。Dock・メニューバーより上にしないと全面を覆えない。
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        // Mission Control 等に出さず、全 Space で表示する。
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // 閉じるときに解放されないようにする（自前で管理する）。
        isReleasedWhenClosed = false

        contentView = overlayView
        // ウィンドウは screen.frame と同じ大きさなので、ローカル座標は
        // 左下 (0,0) 始まりになる。
        setFrame(screen.frame, display: false)
    }

    // borderless でもキーウィンドウになれるようにする（Esc を拾うため）。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
