import AppKit
import SwiftUI

// MARK: - フォントの候補

/// フォントの選択肢。「システム」と、インストール済みのファミリー。
@MainActor
enum FontChoices {
    struct Choice: Hashable {
        let title: String
        /// `TextStyle.fontName` に入れる値（PostScript 名）。システムは空。
        let postScriptName: String
    }

    /// 一度だけ作る（ファミリーは数百あり、1 つずつ解決するため）。
    ///
    /// ファミリー名から `NSFont(name:)` で引くと、和文ファミリー（ヒラギノなど）は
    /// 引けずに一覧から落ちる。代わりにファミリーの構成書体（`availableMembers`）から
    /// 通常の太さ・立体の書体の PostScript 名を取る。
    private static let installed: [Choice] = {
        let manager = NSFontManager.shared
        var choices: [Choice] = []
        var seen: Set<String> = []
        for family in manager.availableFontFamilies {
            guard let name = representativePostScriptName(of: family, manager: manager),
                !seen.contains(name)
            else { continue }
            seen.insert(name)
            choices.append(Choice(title: family, postScriptName: name))
        }
        return choices
    }()

    /// ファミリーの代表の 1 書体の PostScript 名。引けなければ nil（非表示のフォントなど）。
    private static func representativePostScriptName(
        of family: String, manager: NSFontManager
    ) -> String? {
        // 各メンバーは [PostScript 名, スタイル名, ウエイト(0-14), トレイト]。
        let members = manager.availableMembers(ofFontFamily: family) ?? []
        let italic = NSFontTraitMask.italicFontMask.rawValue
        let candidates = members.compactMap { member -> (name: String, weight: Int, italic: Bool)? in
            guard member.count >= 4, let name = member[0] as? String,
                let weight = (member[2] as? NSNumber)?.intValue,
                let traits = (member[3] as? NSNumber)?.uintValue
            else { return nil }
            return (name, weight, traits & italic != 0)
        }
        // 立体のうち、標準（5）に最も近い太さ。
        let best =
            candidates.filter { !$0.italic }.min { abs($0.weight - 5) < abs($1.weight - 5) }
            ?? candidates.first
        if let best, NSFont(name: best.name, size: 12) != nil { return best.name }
        // メンバーが取れないときは従来どおりファミリー名で引く。
        return NSFont(name: family, size: 12)?.fontName
    }

    /// 現在の値が一覧に無い（アンインストールされた等）ときも、選択が空にならないよう足す。
    static func choices(including current: String) -> [Choice] {
        var result = [Choice(title: "システム", postScriptName: "")] + installed
        if !current.isEmpty, !result.contains(where: { $0.postScriptName == current }) {
            result.append(Choice(title: current, postScriptName: current))
        }
        return result
    }
}

extension AnnotationFontWeight {
    var title: String {
        switch self {
        case .regular: "標準"
        case .medium: "中"
        case .semibold: "やや太い"
        case .bold: "太い"
        case .heavy: "極太"
        }
    }
}

// MARK: - 色の変換

extension Color {
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension RGBAColor {
    /// SwiftUI の色から。sRGB に直して成分を取る。
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        self.init(
            red: Double(ns.redComponent), green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
