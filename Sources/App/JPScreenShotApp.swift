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
        coordinator = AppCoordinator()
    }

    // メニューバーアプリなので、ウィンドウを全部閉じても終了しない。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
