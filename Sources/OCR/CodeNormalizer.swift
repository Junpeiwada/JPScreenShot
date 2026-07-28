import Foundation

// コードモードの後処理（要求 6.3）。
//
// Vision は「日本語の文脈」と判断すると記号を全角に寄せる。これは
// 機械的な変換で復元できる（実測例: `(` → `（`、`;` → `；`、`!` → `！`）。
//
// 一方で**字形の混同は補正しない**（6.3 の明示要求）。
// `l`（小文字 L）→ `1`、`O` → `0`、`&&` → `88` などは、文脈がないと
// どちらが正しいか判断できず、正しい文字を壊す危険があるため。
// ユーザーが結果ウィンドウで直す前提とする（4.3）。
enum CodeNormalizer {

    /// 全角 → 半角の対応表。要求 6.3 で列挙された対象を網羅する。
    private static let table: [Character: Character] = {
        var map: [Character: Character] = [:]

        // 括弧類: （）「」［］｛｝ → ()[]{}
        // 「」は角括弧に寄せる（コード中の全角引用符は鍵括弧に化けやすい）。
        map["（"] = "("
        map["）"] = ")"
        map["［"] = "["
        map["］"] = "]"
        map["｛"] = "{"
        map["｝"] = "}"
        map["〔"] = "["
        map["〕"] = "]"
        map["【"] = "["
        map["】"] = "]"
        map["「"] = "["
        map["」"] = "]"
        map["＜"] = "<"
        map["＞"] = ">"

        // 記号: ；：！＝＋－＊／＜＞＆｜％＃＠．，
        map["；"] = ";"
        map["："] = ":"
        map["！"] = "!"
        map["＝"] = "="
        map["＋"] = "+"
        map["－"] = "-"
        map["＊"] = "*"
        map["／"] = "/"
        map["＆"] = "&"
        map["｜"] = "|"
        map["％"] = "%"
        map["＃"] = "#"
        map["＠"] = "@"
        map["．"] = "."
        map["，"] = ","
        map["？"] = "?"
        map["＄"] = "$"
        map["＾"] = "^"
        map["＿"] = "_"
        map["￥"] = "\\"
        map["＼"] = "\\"
        map["’"] = "'"
        map["”"] = "\""
        map["‘"] = "'"
        map["“"] = "\""
        map["｀"] = "`"
        map["～"] = "~"

        // 波ダッシュ・ダッシュ類 → ~ - （コードモードのみ）
        map["〜"] = "~"
        map["－"] = "-"
        map["‐"] = "-"
        map["―"] = "-"
        map["–"] = "-"
        map["—"] = "-"

        // 注意: 長音記号 `ー`(U+30FC) と 読点`、`・句点`。` はこの表に入れない。
        // 無条件に変換すると日本語を壊す（`サーバーエラー` → `サ-バ-エラ-`）。
        // 文脈を見て変換するため contextual() で個別に扱う。

        // 全角空白 → 半角空白
        map["\u{3000}"] = " "

        // 全角英数字 → 半角。ASCII の範囲で一括生成する。
        // 全角 '０'(U+FF10) 〜 'ｚ'(U+FF5A) は ASCII と 0xFEE0 のオフセット。
        for scalar in 0xFF01...0xFF5E {
            guard let full = Unicode.Scalar(scalar),
                  let half = Unicode.Scalar(scalar - 0xFEE0)
            else { continue }
            // 上で明示的に指定したものは上書きしない。
            let key = Character(full)
            if map[key] == nil {
                map[key] = Character(half)
            }
        }

        return map
    }()

    /// 全角記号・英数字を半角へ正規化する。
    ///
    /// 字形の混同（`l`/`1`、`O`/`0` 等）は意図的に補正しない（6.3）。
    static func normalize(_ text: String) -> String {
        let chars = Array(text)
        var result = String()
        result.reserveCapacity(chars.count)

        for (index, char) in chars.enumerated() {
            if let converted = contextual(char, at: index, in: chars) {
                result.append(converted)
            } else {
                result.append(table[char] ?? char)
            }
        }
        return result
    }

    /// 文脈を見て変換するかどうかを決める文字。
    ///
    /// 長音記号 `ー` は「全角ハイフンの誤認識」であることもあるが、
    /// カタカナ語の一部（`サーバー`）であることも多い。読点・句点も
    /// 日本語コメントでは当然そのまま残すべきである。
    /// 前後に日本語があればそのまま残し、無ければ記号として変換する。
    ///
    /// - Returns: 変換後の文字。判断対象外なら nil（通常の表引きに任せる）。
    private static func contextual(
        _ char: Character,
        at index: Int,
        in chars: [Character]
    ) -> Character? {
        let replacement: Character
        switch char {
        case "ー": replacement = "-"
        case "、": replacement = ","
        case "。": replacement = "."
        default: return nil
        }

        let previous = index > 0 ? chars[index - 1] : nil
        let next = index + 1 < chars.count ? chars[index + 1] : nil

        // 前後どちらかが日本語なら日本語の文脈と見なして残す。
        if isJapanese(previous) || isJapanese(next) {
            return char
        }
        return replacement
    }

    /// ひらがな・カタカナ・漢字か。
    private static func isJapanese(_ char: Character?) -> Bool {
        guard let scalar = char?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x309F:   // ひらがな
            return true
        case 0x30A0...0x30FF:   // カタカナ（長音記号 U+30FC を含む）
            return true
        case 0x4E00...0x9FFF:   // CJK 統合漢字
            return true
        case 0x3400...0x4DBF:   // CJK 拡張 A
            return true
        case 0xFF66...0xFF9F:   // 半角カタカナ
            return true
        default:
            return false
        }
    }
}
