import CoreGraphics
import Foundation

// 注釈（矢印・線・四角・円・テキスト・ぼかし・モザイク）のデータ型。
//
// すべて Sendable な値型で、Codable にしてある。将来 Settings へ「種類ごとの
// 最後に使ったスタイル」を保存する（実装計画 P4-4）ほか、PNG への編集情報の
// 埋め込み（画面構成案 6 章の②）へ移れるようにするため。
// そのため CGColor / NSColor / NSFont のような参照型は持たない。
//
// 座標はすべて **画像のポイント座標**（CaptureResult.pointSize の空間、
// 左上原点・y 下向き）。ピクセルでも画面座標でもない。線の太さ・文字サイズ・
// 影の距離もポイントで持つ。書き出し時だけ scale を掛けてピクセルにする。

// MARK: - 色

/// RGBA の値型の色（sRGB、各成分 0...1）。
///
/// CGColor は Codable でも Sendable でもないので、値で持って描くときに変換する。
struct RGBAColor: Sendable, Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` の 16 進から作る。
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// 同じ色とみなせるか（各成分の差が許容内）。プリセットの選択表示などに使う。
    func isClose(to other: RGBAColor, tolerance: Double = 0.01) -> Bool {
        abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance && abs(alpha - other.alpha) <= tolerance
    }

    /// 描画用の CGColor（sRGB）。
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 不透明度だけ差し替えた色。半透明の塗りに使う。
    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    /// 注釈の既定色。スクリーンショットの上で目立つ赤。
    static let red = RGBAColor(red: 0.93, green: 0.16, blue: 0.16)
    static let blue = RGBAColor(red: 0.1, green: 0.45, blue: 0.95)
}

// MARK: - 種類と層

/// 注釈の種類。
enum AnnotationKind: String, Sendable, Codable, CaseIterable {
    case arrow
    case line
    case rect
    case ellipse
    case text
    case blur
    case mosaic

    /// 属する層。重なり順は「元画像 → 範囲加工層 → 図形層」で固定する。
    var layer: AnnotationLayer {
        switch self {
        case .blur, .mosaic: .redaction
        default: .figure
        }
    }

    /// 始点・終点の 2 点で表す線形状か（矢印・線）。ハンドルは両端の 2 点になる。
    var isLinear: Bool { self == .arrow || self == .line }

    /// 始点・終点を対角とする矩形で表す形状か（四角・円・ぼかし・モザイク）。
    var isBoxed: Bool {
        switch self {
        case .rect, .ellipse, .blur, .mosaic: true
        default: false
        }
    }

    /// 後から種類を切り替えられる相手の集合。
    ///
    /// 図形どうし（矢印・線・四角・円）とぼかし⇔モザイクだけ。形状データを
    /// 共通化してあるので、切り替えは kind を書き換えるだけで済む。
    /// テキストは文字列を持つ別物なので切り替えない（自分だけの集合）。
    var switchableKinds: [AnnotationKind] {
        switch self {
        case .arrow, .line, .rect, .ellipse: [.arrow, .line, .rect, .ellipse]
        case .blur, .mosaic: [.blur, .mosaic]
        case .text: [.text]
        }
    }
}

/// 重なり順の層。
enum AnnotationLayer: Int, Sendable, Codable {
    /// ぼかし・モザイク（元画像の直上）。
    case redaction = 0
    /// 図形・テキスト（最前面）。矢印をぼかしの上に置いてもぼけない。
    case figure = 1
}

// MARK: - スタイルの部品

/// 矢印の先端。
enum ArrowHeads: String, Sendable, Codable, CaseIterable {
    case none
    /// 終点側だけ。
    case end
    case both
}

/// 線種。
enum LineDash: String, Sendable, Codable, CaseIterable {
    case solid
    case dashed
}

/// 四角・円の塗り。
enum FillMode: String, Sendable, Codable, CaseIterable {
    case none
    /// 半透明（線の色を薄く敷く）。
    case translucent
    case solid
}

/// 影。distance は真下方向へのずれ（ポイント）。
struct ShadowStyle: Sendable, Codable, Hashable {
    var isOn: Bool = false
    /// ぼかし半径（ポイント）。
    var blur: Double = 4
    /// 下方向へのずれ（ポイント）。
    var distance: Double = 2
}

/// フォントのウエイト。NSFont.Weight に依存しないよう自前の列挙で持つ。
enum AnnotationFontWeight: String, Sendable, Codable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold
    case heavy

    /// NSFontDescriptor の weight トレイト値（-1...1）。NSFont.Weight の定数と同じ値。
    var traitValue: CGFloat {
        switch self {
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        }
    }
}

/// 縁取り（袋文字）。
struct OutlineStyle: Sendable, Codable, Hashable {
    var isOn: Bool = true
    var color: RGBAColor = .black
    /// 縁の太さ（ポイント）。文字の外側へ張り出す幅。
    var width: Double = 3
}

/// テキストのスタイル。
struct TextStyle: Sendable, Codable, Hashable {
    /// フォント名（PostScript 名）。空ならシステムフォント。
    var fontName: String = ""
    var weight: AnnotationFontWeight = .bold
    /// 文字サイズ（ポイント）。
    var size: Double = 24
    var color: RGBAColor = .white
    var outline: OutlineStyle = OutlineStyle()
}

/// ぼかし・モザイクの形。
enum RedactionShape: String, Sendable, Codable, CaseIterable {
    case rectangle
    case ellipse
}

/// ぼかし・モザイクのスタイル。
struct RedactionStyle: Sendable, Codable, Hashable {
    /// 強さ（ポイント）。ぼかしならガウスぼかしの半径、モザイクならブロック 1 辺。
    /// 両者を同じ値で持つのは、ぼかし⇔モザイクの切り替えで強さを保つため。
    var strength: Double = 12
    var shape: RedactionShape = .rectangle

    // MARK: 強さの範囲（P4-5）

    // ぼかし・モザイクの目的は「読めなくすること」。弱すぎると、隠したつもりの文字が
    // 人の目や拡大で読めてしまう事故になるので、下限を設ける。
    // - ぼかし: 半径 6pt 未満だと、12〜16pt 程度の本文は輪郭が残って判読できる
    // - モザイク: ブロック 8pt 未満だと、1 文字（約 12〜16pt）が 2×2 ブロック以上に
    //   分かれて形が残り、読めてしまう
    // 上限は操作しやすさのための目安（これ以上は画像が塗りつぶされるだけ）。

    /// ぼかし半径の下限（ポイント）。
    static let minimumBlurStrength: Double = 6
    /// モザイクのブロック 1 辺の下限（ポイント）。
    static let minimumMosaicStrength: Double = 8
    /// 強さの上限（ポイント）。
    static let maximumStrength: Double = 40

    /// 種類ごとの強さの範囲。スライダーの範囲にも使う。
    static func strengthRange(for kind: AnnotationKind) -> ClosedRange<Double> {
        let minimum = kind == .mosaic ? minimumMosaicStrength : minimumBlurStrength
        return minimum...maximumStrength
    }

    /// 種類に合わせて強さを範囲内へ収めた値。
    /// ぼかし⇔モザイクの切り替えで強さを保つため、下限は切り替え後の種類で掛け直す。
    func clamped(for kind: AnnotationKind) -> RedactionStyle {
        var result = self
        let range = Self.strengthRange(for: kind)
        result.strength = min(max(strength, range.lowerBound), range.upperBound)
        return result
    }
}

/// 注釈 1 件分のスタイル。
///
/// 種類ごとに使う項目が違う（ぼかしは色を持たない等）が、1 つの型に全項目を
/// 持たせる。種類を切り替えたとき、使わなかった項目の値が消えず、戻したときに
/// 元の設定が残るようにするため。どの項目が効くかは画面構成案 2 章の表のとおり。
struct AnnotationStyle: Sendable, Codable, Hashable {
    /// 線・図形の色。
    var color: RGBAColor = .red
    /// 線の太さ（ポイント）。
    var lineWidth: Double = 4
    var arrowHeads: ArrowHeads = .end
    var dash: LineDash = .solid
    var fill: FillMode = .none
    var shadow: ShadowStyle = ShadowStyle()
    var text: TextStyle = TextStyle()
    var redaction: RedactionStyle = RedactionStyle()
}

// MARK: - 注釈本体

/// 注釈 1 件。
///
/// 形は種類によらず `start` / `end` の 2 点で持つ。
/// - 矢印・線: 始点から終点への線分
/// - 四角・円・ぼかし・モザイク: 2 点を対角とする矩形（どの角が始点でもよい）
/// - テキスト: `start` が左上の原点。`end` は使わない（外接矩形は文字列から計算する）
///
/// 形を共通にしてあるので、図形どうしやぼかし⇔モザイクは kind を書き換えるだけで
/// 切り替えられる。
struct Annotation: Sendable, Codable, Hashable, Identifiable {
    var id: UUID
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    /// テキスト注釈の文字列（複数行は改行区切り）。他の種類では空。
    var text: String
    var style: AnnotationStyle

    init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        text: String = "",
        style: AnnotationStyle = AnnotationStyle()
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.style = style
    }

    var layer: AnnotationLayer { kind.layer }
}
