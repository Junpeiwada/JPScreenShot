import AppKit

// 範囲選択用のオーバーレイウィンドウ。1 スクリーンにつき 1 つ作る。
//
// 実装計画 6.3 の注意点に対応する:
// - borderless な NSWindow は既定でキーウィンドウになれないため
//   canBecomeKey を上書きして Esc やマウスイベントを受け取れるようにする
// - level を screenSaver 相当にして最前面（Dock やメニューバーより上）に出す
final class OverlayWindow: NSWindow {

    let overlayView: OverlayView

    convenience init(screen: NSScreen) {
        // contentRect は screen.frame（グローバル座標）をそのまま渡す。
        // ウィンドウが画面全体と一致するので、ビューのローカル座標は
        // 左下 (0,0) 始まりになる。
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayView.backingScale = screen.backingScaleFactor
        // 対象スクリーンに確実に配置する。
        setFrame(screen.frame, display: false)
    }

    // NSWindow の指定イニシャライザは
    // init(contentRect:styleMask:backing:defer:) の 1 つだけ
    // （screen: 付きは convenience。SDK の NSWindow.h で確認済み）。
    //
    // これを override せずに独自の init を定義すると、継承した指定
    // イニシャライザが「未実装」のまま残り、AppKit が内部的に呼んだ時点で
    // クラッシュする:
    //   Fatal error: Use of unimplemented initializer
    //   'init(contentRect:styleMask:backing:defer:)'
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        overlayView = OverlayView()
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        configure()
    }

    private func configure() {
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
    }

    // borderless でもキーウィンドウになれるようにする（Esc を拾うため）。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
