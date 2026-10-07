import Foundation

// 左のツールレールで選ぶツール。
//
// 選択ツール 1 つと、注釈の種類ごとの描画ツール。種類との対応だけを持つ
// 純粋な型で、画面にも権限にも依存しない（テストしやすい）。
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case select
    case arrow
    case line
    case rect
    case ellipse
    case text
    case blur
    case mosaic

    var id: String { rawValue }

    /// このツールで新規作成する注釈の種類。選択ツールは作らないので nil。
    var kind: AnnotationKind? {
        switch self {
        case .select: nil
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .text: .text
        case .blur: .blur
        case .mosaic: .mosaic
        }
    }

    /// レールのツールチップ・アクセシビリティ用の名前。
    var title: String {
        switch self {
        case .select: "選択"
        case .arrow: "矢印"
        case .line: "線"
        case .rect: "四角"
        case .ellipse: "円"
        case .text: "テキスト"
        case .blur: "ぼかし"
        case .mosaic: "モザイク"
        }
    }

    /// ツールチップ。「矢印（A）」の形で、キーは AnnotationKeyboard の対応表から引く。
    var helpText: String {
        guard let key = AnnotationKeyboard.shortcutKey(for: self) else { return title }
        return "\(title)（\(key)）"
    }

    /// SF Symbols の名前。
    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .text: "character.textbox"
        case .blur: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .mosaic: "squareshape.split.3x3"
        }
    }
}
