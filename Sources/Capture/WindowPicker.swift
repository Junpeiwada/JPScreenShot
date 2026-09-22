import AppKit
import ScreenCaptureKit

// クリック位置からキャプチャ対象のウィンドウを決める（要求 4.2 / CAP-06）。
//
// オーバーレイは全画面を覆っているため、AppKit のヒットテストは使えない
// （常に自分のオーバーレイが当たる）。ウィンドウの一覧を自前で走査して
// 「その座標で実際に見えている最前面のウィンドウ」を選ぶ。
//
// ★重なり順の出どころ（ここが要）:
// かつては `SCShareableContent.windows` の並びを前面→背面として扱って
// いたが、**この並びは重なり順ではない**。実測（同一タイミングで両方を
// 取得して比較）:
//
//   CGWindowList:        1816(Code) → 3954(Code) → 1813 → 1815 → 3979 …
//   SCShareableContent:  3973(HDRForge) → 2430(Finder) → 408 → 394 → 3834 …
//
// 画面に実際に見えていたのは 1816 一枚で、CGWindowList の側が正しかった。
// SCShareableContent の順を信じると、完全に隠れた別ウィンドウを掴む。
// そのため重なり順は `CGWindowListCopyWindowInfo` から取り、windowID で
// SCWindow に対応づける（この API は前面→背面の順を保証している）。
@MainActor
enum WindowPicker {

    /// カーソル下のウィンドウと、その見え方。
    struct Hovered {
        /// キャプチャ対象のウィンドウ。
        let window: SCWindow
        /// 画面で実際に見えている領域（CoreGraphics 座標、重なりなしの矩形群）。
        ///
        /// 手前のウィンドウに覆われた部分を差し引いてある。ハイライトを
        /// この形に合わせることで「見えているものが撮れる」と一致させる。
        let visibleRects: [CGRect]
        /// 「アプリ名 — ウィンドウタイトル」形式の表示名。
        ///
        /// 同じ位置・同じ大きさのウィンドウが重なっていると枠だけでは
        /// どれを選んでいるか分からないため、名前で示す。
        let label: String
    }

    /// 前面→背面に並べ替え済みのキャプチャ候補。
    ///
    /// 重なり順の取得は選択の開始時に一度だけ行う。オーバーレイを出して
    /// いる間は他アプリのウィンドウが前後しないため、カーソルが動くたびに
    /// 取り直す必要がない。
    struct Candidates {
        /// 前面→背面の順。
        fileprivate let ordered: [SCWindow]

        /// どの候補よりも手前にあって画面を覆っているもの（CoreGraphics 座標）。
        ///
        /// 想定しているのは自アプリの結果ウィンドウ・環境設定ウィンドウ。
        /// これらは候補にはならない（自プロセスなので `isSelectable` で
        /// 落ちる）が、実際に他アプリのウィンドウを覆い隠している。数えないと
        /// 「結果ウィンドウの陰にいて見えないウィンドウ」を選べてしまう。
        fileprivate let foregroundOccluders: [CGRect]
    }

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
    ///
    /// フルスクリーンのアプリがある画面では、その下のウィンドウがすべて
    /// ここで落ちる。結果として「フルスクリーンのアプリしか撮れない」。
    private static let minimumVisibleAreaRatio: CGFloat = 0.02

    /// 重なり順を解決した候補一覧を作る。
    /// - Parameters:
    ///   - content: 先読みしておいた共有可能コンテンツ。
    ///   - foregroundOccluders: どの候補よりも手前にある遮蔽物
    ///     （CoreGraphics 座標）。自アプリの結果ウィンドウなど。
    ///
    /// ★ここに Dock・メニューバー・壁紙は渡さないこと。
    /// これらのウィンドウ矩形は実際の描画範囲と一致しない。実測では Dock の
    /// 矩形が画面全体（0,0 3008x1692）として報告された。遮蔽物として数えると
    /// 画面上のすべてが「隠れている」ことになり、何も選べなくなる。
    static func candidates(
        from content: SCShareableContent,
        foregroundOccluders: [CGRect] = []
    ) -> Candidates {
        let selectable = content.windows.filter(isSelectable)
        let zOrder = zOrderByWindowID()

        // 重なり順が取れなかったとき（API が nil を返した場合）。
        //
        // ここで候補を空にすると、クリックしても何も起きないアプリになる。
        // 原因を突き止める手掛かりも画面には出ない。順序の正しさは失われるが、
        // 撮れないよりは撮れた方がましなので、並べ替えずに縮退させる。
        guard !zOrder.isEmpty else {
            return Candidates(ordered: selectable, foregroundOccluders: foregroundOccluders)
        }

        let ordered = selectable
            // 重なり順のリストに載っていないものは今この画面に出ていない。
            // SCShareableContent 側には残っていることがあるので落とす。
            .compactMap { window -> (window: SCWindow, z: Int)? in
                guard let z = zOrder[window.windowID] else { return nil }
                return (window, z)
            }
            .sorted { $0.z < $1.z }
            .map(\.window)
        return Candidates(ordered: ordered, foregroundOccluders: foregroundOccluders)
    }

    /// AppKit グローバル座標の点で見えているウィンドウを返す。該当なしなら nil。
    /// - Parameters:
    ///   - appKitPoint: マウス位置（AppKit グローバル座標、左下原点）。
    ///   - candidates: `candidates(from:)` で作った候補一覧。
    static func hitTest(at appKitPoint: CGPoint, in candidates: Candidates) -> Hovered? {
        // SCWindow.frame は CoreGraphics 座標（左上原点）なので座標系を合わせる。
        let cgPoint = ScreenGeometry.convertPointToCoreGraphics(appKitPoint)
        let ordered = candidates.ordered

        // その点が自アプリのウィンドウに覆われていれば、そこには他アプリの
        // ウィンドウは見えていない。候補を探すまでもない。
        guard !candidates.foregroundOccluders.contains(where: { $0.contains(cgPoint) })
        else {
            return nil
        }

        // その点を含む最前面のウィンドウを探す。
        //
        // 重なり順が正しければ、これがそのままユーザーの見ているウィンドウに
        // なる。より手前のウィンドウがこの点を覆っているなら、そちらが先に
        // ヒットするからである。
        guard let index = ordered.firstIndex(where: { $0.frame.contains(cgPoint) }) else {
            return nil
        }
        let target = ordered[index]

        // 手前にあるもので覆われた部分を差し引く。
        let occluders = ordered[..<index].map(\.frame) + candidates.foregroundOccluders
        let visible = visibleRects(of: target.frame, occludedBy: occluders)

        // 事実上見えていないウィンドウは対象にしない（ユーザー要求）。
        //
        // 点そのものは見えていることが確定しているが、ウィンドウの大半が
        // 隠れている場合はある。端が数ピクセルのぞいているだけのものを
        // 撮れても実用にならないので、ここで落とす。
        let visibleArea = visible.reduce(0) { $0 + $1.width * $1.height }
        guard isEffectivelyVisible(visibleArea: visibleArea, of: target.frame)
        else {
            return nil
        }

        let label = label(
            applicationName: target.owningApplication?.applicationName ?? "",
            windowTitle: target.title ?? ""
        )
        return Hovered(window: target, visibleRects: visible, label: label)
    }

    /// 見えている面積が「対象として選ばせてよい」量に達しているか。
    ///
    /// 判定を `hitTest` に埋めると SCWindow なしでは確かめられない。
    /// 閾値の意味を固定しておきたいので切り出してある。
    static func isEffectivelyVisible(visibleArea: CGFloat, of frame: CGRect) -> Bool {
        let totalArea = frame.width * frame.height
        guard totalArea > 0 else { return false }
        return visibleArea / totalArea > minimumVisibleAreaRatio
    }

    /// ウィンドウを前面→背面に並べたときの順位を windowID 引きで返す。
    ///
    /// `CGWindowListCopyWindowInfo` は `.optionOnScreenOnly` を指定すると
    /// 画面に出ているウィンドウを前面→背面の順で返す（順序が保証されて
    /// いるのはこの API だけ）。
    ///
    /// このマップは並べ替えだけでなく候補の絞り込みも兼ねる（ここに
    /// 載っていないウィンドウは候補から落ちる）。`.excludeDesktopElements`
    /// を付けているのはそれを承知のうえで、壁紙とデスクトップアイコンを
    /// 選ばせないため。`isSelectable` のバンドル ID 列挙から漏れたものも
    /// ここで落ちる。
    ///
    /// 空を返したら「取得に失敗した」の意味になる（画面に 1 枚も
    /// ウィンドウがない状態でも、メニューバーや Dock は必ず載る）。
    private static func zOrderByWindowID() -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        order.reserveCapacity(list.count)
        for (index, info) in list.enumerated() {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            order[id] = index
        }
        return order
    }

    /// キャプチャ対象になりうるウィンドウか。
    private static func isSelectable(_ window: SCWindow) -> Bool {
        // isOnScreen は「Space 上に配置されている」の意味。他のウィンドウに
        // 隠れていても true になるため、これだけでは可視判定にならない
        // （重なりの判定は visibleRects で別途行う）。
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

    /// ハイライトに添える表示名。
    static func label(applicationName: String, windowTitle: String) -> String {
        let app = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if app.isEmpty { return title }
        // タイトルがアプリ名と同じなら重ねて出しても情報が増えない。
        if title.isEmpty || title == app { return app }
        return "\(app) — \(title)"
    }

    /// 手前のウィンドウ群に覆われた結果、実際に見えている領域を返す。
    ///
    /// 返る矩形どうしは重ならないので、面積は単純に足せる。
    ///
    /// 覆う矩形どうしが重なっていると単純な引き算では過小評価になる
    /// （同じ場所を二重に引く）。矩形の数は数十程度なので、走査線方式で
    /// 正確に求める: 対象を X 座標の切れ目で縦の帯に分け、各帯ごとに
    /// 「覆われていない Y 区間」を求めて矩形に起こす。
    static func visibleRects(of target: CGRect, occludedBy occluders: [CGRect]) -> [CGRect] {
        guard target.width > 0, target.height > 0 else { return [] }

        // 対象と実際に重なるものだけを見る。
        let clipped = occluders.compactMap { rect -> CGRect? in
            let i = rect.intersection(target)
            return (i.isNull || i.isEmpty) ? nil : i
        }
        guard !clipped.isEmpty else { return [target] }

        // 帯の境界になる X 座標を集める。
        var xs: Set<CGFloat> = [target.minX, target.maxX]
        for r in clipped {
            xs.insert(r.minX)
            xs.insert(r.maxX)
        }
        let bounds = xs.sorted()

        var result: [CGRect] = []
        for i in 0..<(bounds.count - 1) {
            let left = bounds[i]
            let right = bounds[i + 1]
            guard right > left else { continue }

            // この帯を覆う Y 区間を集める。
            // 帯の内側を代表する 1 点（中央）で判定すれば、境界で
            // 半端に掛かる矩形を数え間違えない。
            let midX = (left + right) / 2
            let intervals = clipped
                .filter { $0.minX <= midX && midX < $0.maxX }
                .map { (low: $0.minY, high: $0.maxY) }
                .sorted { $0.low < $1.low }

            // 覆われていない Y 区間（＝隙間）を拾って矩形にする。
            var cursor = target.minY
            for interval in intervals {
                if interval.low > cursor {
                    result.append(
                        CGRect(x: left, y: cursor, width: right - left, height: interval.low - cursor)
                    )
                }
                cursor = max(cursor, interval.high)
                if cursor >= target.maxY { break }
            }
            if cursor < target.maxY {
                result.append(
                    CGRect(x: left, y: cursor, width: right - left, height: target.maxY - cursor)
                )
            }
        }
        return mergingHorizontallyAdjacent(result)
    }

    /// 横に隣り合っていて上下が揃っている矩形どうしをつなぐ。
    ///
    /// 走査線で切った帯は、覆われ方が同じでも X の切れ目ごとに別々の矩形に
    /// なる。塗りは矩形群の和でクリップしてから 1 回で行うので、分かれた
    /// ままでも継ぎ目は出ない。まとめる理由は別にあり、ラベルの置き場所を
    /// 「最も広い可視矩形」で選んでいるため（OverlayView）。細い帯に
    /// 分かれたままだと、実際には広く見えているウィンドウなのに置き場所が
    /// 見つからずラベルが出ない。面積は変わらない。
    private static func mergingHorizontallyAdjacent(_ rects: [CGRect]) -> [CGRect] {
        let sorted = rects.sorted {
            ($0.minY, $0.minX) < ($1.minY, $1.minX)
        }
        var merged: [CGRect] = []
        for rect in sorted {
            if let last = merged.last,
               isClose(last.minY, rect.minY),
               isClose(last.maxY, rect.maxY),
               isClose(last.maxX, rect.minX) {
                merged[merged.count - 1].size.width += rect.width
            } else {
                merged.append(rect)
            }
        }
        return merged
    }

    /// 座標が同じとみなせるか。
    ///
    /// 結合済みの矩形の maxX は幅を足し込んで作るため、元の X 座標との
    /// 比較が浮動小数の誤差で外れうる（`a + (b-a) + (c-b) == c` は保証
    /// されない）。整数座標なら問題ないが、スケーリング解像度では
    /// ウィンドウ矩形に小数が入る。厳密比較で外すと静かにラベルが
    /// 出なくなるだけなので、原因が分かりにくい。
    private static func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < coordinateTolerance
    }

    /// 同一座標とみなす許容誤差（ポイント）。1 ピクセル未満に収める。
    private static let coordinateTolerance: CGFloat = 0.01
}
