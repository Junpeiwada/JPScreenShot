import Sparkle

// アプリ内自動更新（Sparkle）の入り口。
//
// 更新フィード（SUFeedURL）と署名検証鍵（SUPublicEDKey）は Info.plist に
// 置く。値の実体は project.yml 側で管理している（そちらが真実のソース）。
//
// 自動確認の有効・無効は Sparkle 自身が UserDefaults に持つため、
// アプリ側の Settings では管理しない。二重に状態を持つと食い違うので、
// 参照・更新はどちらも updater 経由で行う。
@MainActor
final class UpdaterController {

    /// Sparkle の標準 UI（更新ダイアログ・進捗・再起動）をそのまま使う。
    /// startingUpdater: true で、Info.plist の SUScheduledCheckInterval に
    /// 従った定期確認が起動時から動き出す。
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// メニュー「更新を確認…」から呼ぶ。結果はすべて Sparkle の UI が表示する
    /// （最新である場合の「最新です」も含む）ため、呼び側で分岐は要らない。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 起動時の自動確認を行うか。環境設定のトグルと結びつける。
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 最後に更新確認した時刻。環境設定の表示に使う（未確認なら nil）。
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
