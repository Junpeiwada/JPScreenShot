import AppKit

// 座標系の変換を 1 か所に集約する。
//
// 実装計画 6.1 のとおり macOS には座標系が 3 つ混在し、マルチディスプレイ
// （CAP-03）で最も壊れやすい。各所で場当たりに符号を反転させないため、
// 変換はすべてここを通す。
//
// | 座標系 | 原点 | 使う場所 |
// |---|---|---|
// | AppKit (NSScreen) | 左下・Y 上向き | オーバーレイ・マウスイベント |
// | CoreGraphics (CGDisplay) | 左上・Y 下向き | SCDisplay の対応付け |
// | ピクセル | — | config.width/height |
enum ScreenGeometry {

    /// 主画面の高さ。AppKit ↔ CoreGraphics の Y 反転の基準になる。
    ///
    /// CoreGraphics の原点は「主画面の左上」であり、全画面統合矩形の上端では
    /// ないことに注意する。ここを取り違えると副画面で位置がずれる。
    static var primaryScreenHeight: CGFloat {
        // NSScreen.screens.first が主画面（AppKit 原点を含む画面）。
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AppKit 座標（左下原点）→ CoreGraphics 座標（左上原点）へ変換する。
    ///
    /// ScreenCaptureKit の `sourceRect` は CoreGraphics 系のポイントで指定する。
    static func convertToCoreGraphics(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// CoreGraphics 座標（左上原点）→ AppKit 座標（左下原点）へ変換する。
    ///
    /// `SCWindow.frame` は CoreGraphics 系で来るため、それをオーバーレイ上に
    /// 描く（ウィンドウ枠のハイライト）ときにこちらを使う。
    /// 変換式は `convertToCoreGraphics` と同一の対合であり、往復で元に戻る。
    static func convertToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit 座標の点 → CoreGraphics 座標の点へ変換する。
    ///
    /// 矩形と違い高さの引き算がないため、`convertToCoreGraphics` を
    /// 高さ 0 の矩形で代用すると誤りやすい。点用に分けておく。
    static func convertPointToCoreGraphics(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// 指定した AppKit 座標の矩形を最も多く含むスクリーンを返す。
    ///
    /// 範囲選択がディスプレイ境界をまたいだ場合、交差面積が最大の画面を採用する。
    /// 同面積のときは `NSScreen.screens` の先頭側（主画面優先）を返し、
    /// 挙動を決定的にする。
    static func screen(containing rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = area(of: screen.frame.intersection(rect))
            // 厳密な > で比較するため、同面積では先に見つけた方が残る。
            if overlap > bestArea {
                bestArea = overlap
                best = screen
            }
        }
        return bestArea > 0 ? best : nil
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    /// スクリーンの CoreGraphics ディスプレイ ID。SCDisplay との対応付けに使う。
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }
}
