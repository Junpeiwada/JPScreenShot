import AppKit
import ScreenCaptureKit

// クリック位置からキャプチャ対象のウィンドウを決める（要求 4.2 / CAP-06）。
//
// オーバーレイは全画面を覆っているため、AppKit のヒットテストは使えない
// （常に自分のオーバーレイが当たる）。SCShareableContent.windows を
// 自前で走査して「その座標にある最前面のウィンドウ」を選ぶ。
//
// 並び順について（実測で確認済み）:
// `SCShareableContent.windows` の順は **前面→背面** であり、
// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`（前面→背面が保証されて
// いる）の順と完全に一致した。したがって「先に見つかったものが前面」
// として扱ってよい。
@MainActor
enum WindowPicker {

    /// キャプチャ対象にしないウィンドウの所有アプリ（バンドル ID）。
    ///
    /// 壁紙・メニューバー・Dock を候補から外す。これらは「アプリのウィンドウ」
    /// としてクリックする対象ではなく、全画面を覆う巨大な矩形として候補に
    /// 混ざると他のウィンドウを選べなくなる。
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.dock",              // Dock 本体・Dock が描く壁紙レイヤ
        "com.apple.WindowManager",     // ステージマネージャ・壁紙
        "com.apple.controlcenter",     // メニューバー右側のステータス項目
        "com.apple.systemuiserver",    // 旧来のメニューバー項目
        "com.apple.notificationcenterui",
    ]

    /// ウィンドウレイヤの上限。
    ///
    /// 通常のアプリウィンドウは layer 0。メニューバー・Dock・ステータス項目・
    /// ポップアップは正の値を持つ。0 以外を外すことで、バンドル ID の列挙から
    /// 漏れたシステム UI も併せて弾ける。
    private static let normalWindowLayer = 0

    /// 極端に小さいウィンドウは候補にしない（ピクセルではなくポイント）。
    ///
    /// 幅・高さが数ポイントの不可視ウィンドウを掴んでしまうと、
    /// 「クリックしたのに何も撮れていない」状態になる。
    private static let minimumSideLengthInPoints: CGFloat = 8

    /// 「隠れている」と判断する可視面積の割合。
    ///
    /// 前面のウィンドウに覆われた結果、これ以下しか見えていないウィンドウは
    /// 候補から外す（ユーザー要求「見えていない window は対象にしなくてよい」）。
    /// 完全一致（0%）ではなく余裕を持たせているのは、数ピクセルだけ端が
    /// のぞいているウィンドウを選べても実用にならないため。
    private static let minimumVisibleAreaRatio: CGFloat = 0.02

    /// AppKit グローバル座標の点にあるウィンドウを返す。該当なしなら nil。
    /// - Parameters:
    ///   - appKitPoint: マウス位置（AppKit グローバル座標、左下原点）。
    ///   - content: 先読みしておいた共有可能コンテンツ。
    static func window(at appKitPoint: CGPoint, in content: SCShareableContent) -> SCWindow? {
        // SCWindow.frame は CoreGraphics 座標（左上原点）なので座標系を合わせる。
        let cgPoint = ScreenGeometry.convertPointToCoreGraphics(appKitPoint)

        // 前面→背面の順を保ったまま、対象になりうるものだけに絞る。
        let ordered = content.windows.filter(isSelectable)

        // クリック点を含む最前面のウィンドウを探す。
        //
        // 手前のウィンドウに覆われている領域はクリックできないので、
        // 「その点を含む最初のもの」がユーザーの見ているウィンドウになる。
        // 面積の比較は不要（順序が信頼できることを実測で確認済み）。
        guard let index = ordered.firstIndex(where: { $0.frame.contains(cgPoint) }) else {
            return nil
        }
        let target = ordered[index]

        // 見えていないウィンドウは対象にしない（ユーザー要求）。
        //
        // ここに到達した時点で「クリック点は覆われていない」ことは確定して
        // いるが、点が見えていてもウィンドウの大半が隠れている場合はある。
        // ただしその場合もユーザーはその点を見てクリックしているので、
        // 意図に反しない。ここで弾くのは「事実上見えていない」ものだけ。
        let occluders = ordered[..<index].map(\.frame)
        guard visibleAreaRatio(of: target.frame, occludedBy: occluders) > minimumVisibleAreaRatio
        else {
            return nil
        }
        return target
    }

    /// キャプチャ対象になりうるウィンドウか。
    private static func isSelectable(_ window: SCWindow) -> Bool {
        // isOnScreen は「Space 上に配置されている」の意味。他のウィンドウに
        // 隠れていても true になるため、これだけでは可視判定にならない
        // （重なりの判定は visibleAreaRatio で別途行う）。
        guard window.isOnScreen else { return false }
        guard window.windowLayer == normalWindowLayer else { return false }
        guard window.frame.width >= minimumSideLengthInPoints,
              window.frame.height >= minimumSideLengthInPoints
        else { return false }

        guard let app = window.owningApplication else { return false }
        // 自アプリのウィンドウ（オーバーレイ・結果ウィンドウ）は撮らない。
        guard app.processID != ProcessInfo.processInfo.processIdentifier else { return false }
        guard !excludedBundleIdentifiers.contains(app.bundleIdentifier) else { return false }
        return true
    }

    /// 手前のウィンドウ群に覆われた結果、どれだけ見えているかの割合（0...1）。
    ///
    /// 覆う矩形どうしが重なっていると単純な面積の足し算では過大評価になる
    /// （同じ場所を二重に数える）。矩形の数は数十程度なので、走査線方式で
    /// 正確に求める: 対象を X 座標の切れ目で縦の帯に分け、各帯ごとに
    /// Y 区間の合併長を出して足し合わせる。
    private static func visibleAreaRatio(
        of target: CGRect,
        occludedBy occluders: [CGRect]
    ) -> CGFloat {
        let targetArea = target.width * target.height
        guard targetArea > 0 else { return 0 }

        // 対象と実際に重なるものだけを見る。
        let clipped = occluders.compactMap { rect -> CGRect? in
            let i = rect.intersection(target)
            return (i.isNull || i.isEmpty) ? nil : i
        }
        guard !clipped.isEmpty else { return 1 }

        // 帯の境界になる X 座標を集める。
        var xs: Set<CGFloat> = [target.minX, target.maxX]
        for r in clipped {
            xs.insert(r.minX)
            xs.insert(r.maxX)
        }
        let bounds = xs.sorted()

        var occludedArea: CGFloat = 0
        for i in 0..<(bounds.count - 1) {
            let left = bounds[i]
            let right = bounds[i + 1]
            let bandWidth = right - left
            guard bandWidth > 0 else { continue }

            // この帯を覆う Y 区間を集めて合併長を求める。
            // 帯の内側を代表する 1 点（中央）で判定すれば、境界で
            // 半端に掛かる矩形を数え間違えない。
            let midX = (left + right) / 2
            let intervals = clipped
                .filter { $0.minX <= midX && midX < $0.maxX }
                .map { ($0.minY, $0.maxY) }
                .sorted { $0.0 < $1.0 }
            guard !intervals.isEmpty else { continue }

            var mergedLength: CGFloat = 0
            var currentStart = intervals[0].0
            var currentEnd = intervals[0].1
            for (start, end) in intervals.dropFirst() {
                if start > currentEnd {
                    mergedLength += currentEnd - currentStart
                    currentStart = start
                    currentEnd = end
                } else {
                    currentEnd = max(currentEnd, end)
                }
            }
            mergedLength += currentEnd - currentStart
            occludedArea += bandWidth * mergedLength
        }

        return max(0, (targetArea - occludedArea) / targetArea)
    }
}
