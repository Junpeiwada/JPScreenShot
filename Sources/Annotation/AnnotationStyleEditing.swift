import Foundation

// 色・太さのプリセットと、「どの種類にどの項目が効くか」の判断。
//
// レール（ToolRail）の色・太さは、種類によって効く先が違う。
// - 色: 線・矢印・四角・円は線の色、テキストは文字色（text.color）。ぼかし・モザイクは色を持たない
// - 太さ: 線・矢印・四角・円の線の太さだけ。テキストは無視する
//   （縁の太さに割り当てると、細 3・中 5・太 9 のどれも文字サイズ 24 に対して太すぎ、
//   縁が文字を潰す。縁の太さはポップオーバーで個別に決める）。ぼかし・モザイクも持たない
// 画面に依存しない純粋な処理にして、テストできるようにしてある。
enum AnnotationStyleEditing {

    // MARK: プリセット

    /// 色のプリセット（レールに並べる順）。
    static let presetColors: [RGBAColor] = [
        RGBAColor(hex: 0xFF3B30),  // 赤
        RGBAColor(hex: 0xFFCC00),  // 黄
        RGBAColor(hex: 0x34C759),  // 緑
        RGBAColor(hex: 0x007AFF),  // 青
        RGBAColor(hex: 0x000000),  // 黒
        RGBAColor(hex: 0xFFFFFF),  // 白
    ]

    /// プリセットの色名（`presetColors` と同じ並び）。アクセシビリティ・ツールチップ用。
    static let presetColorNames: [String] = ["赤", "黄", "緑", "青", "黒", "白"]

    /// プリセット色の名前。プリセット以外（カラーパネルで選んだ色）は nil。
    static func presetName(of color: RGBAColor) -> String? {
        guard let index = presetColors.firstIndex(where: { $0.isClose(to: color) }) else {
            return nil
        }
        return presetColorNames[index]
    }

    /// 太さのプリセット（ポイント）。
    enum Thickness: CaseIterable, Sendable {
        case thin, medium, thick

        var points: Double {
            switch self {
            case .thin: 3
            case .medium: 5
            case .thick: 9
            }
        }

        var title: String {
            switch self {
            case .thin: "細"
            case .medium: "中"
            case .thick: "太"
            }
        }
    }

    // MARK: どの種類に効くか

    /// レールの色が効く種類。
    static func supportsColor(_ kind: AnnotationKind) -> Bool {
        kind.layer == .figure
    }

    /// レールの太さが効く種類。
    static func supportsLineWidth(_ kind: AnnotationKind) -> Bool {
        kind.layer == .figure && kind != .text
    }

    // MARK: カラーパネルの変更を受け付けるか

    /// 選択が変わってから、カラーパネルの変更を受け付けるまでの待ち（秒）。
    static let pickerSettleInterval: TimeInterval = 0.3
    /// 「同じ色」とみなす差。カラーパネルの微調整を捨てないよう極小にする
    /// （NSColor 往復の丸め誤差だけ吸収する）。
    static let pickerColorTolerance = 0.0005

    /// カラーパネル（ColorPicker）から届いた色を適用するか。
    ///
    /// - `currentColors` の全員がすでにその色なら何もしない（変化なし）。色がばらばらの
    ///   複数選択では、先頭と同じ色を選んでも適用する。
    /// - 選択が変わった直後（`settle` 秒以内）に届いた色は、前の選択の色が遅れて届いた
    ///   ものかもしれないので捨てる。
    static func shouldAcceptPickerColor(
        _ color: RGBAColor,
        currentColors: [RGBAColor],
        secondsSinceSelectionChange: TimeInterval,
        settle: TimeInterval = pickerSettleInterval
    ) -> Bool {
        if !currentColors.isEmpty,
            currentColors.allSatisfy({ $0.isClose(to: color, tolerance: pickerColorTolerance) })
        {
            return false
        }
        return secondsSinceSelectionChange > settle
    }

    // MARK: 読み取り・書き込み

    /// そのスタイルでの「色」。テキストは文字色、それ以外は線の色。
    static func color(of style: AnnotationStyle, kind: AnnotationKind) -> RGBAColor? {
        guard supportsColor(kind) else { return nil }
        return kind == .text ? style.text.color : style.color
    }

    /// 色を差し替えたスタイル。効かない種類ではそのまま返す。
    static func setting(color: RGBAColor, on style: AnnotationStyle, kind: AnnotationKind)
        -> AnnotationStyle
    {
        guard supportsColor(kind) else { return style }
        var result = style
        if kind == .text {
            result.text.color = color
        } else {
            result.color = color
        }
        return result
    }

    /// 線の太さを差し替えたスタイル。効かない種類ではそのまま返す。
    static func setting(lineWidth: Double, on style: AnnotationStyle, kind: AnnotationKind)
        -> AnnotationStyle
    {
        guard supportsLineWidth(kind) else { return style }
        var result = style
        result.lineWidth = lineWidth
        return result
    }
}

extension AnnotationStyle {
    /// 種類ごとの初期スタイル（まだ何も記憶していないとき）。
    /// 赤 #FF3B30・太さ 5・影あり。ただしテキストは影なし
    /// （白文字に黒縁の袋文字が既定で、さらに影を足すと濁って見える）。
    static func initialStyle(for kind: AnnotationKind) -> AnnotationStyle {
        var style = AnnotationStyle.initialDrawingStyle
        if kind == .text { style.shadow.isOn = false }
        return style
    }
}
