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

        // 波ダッシュ・長音: ～ ー → ~ -（コードモードのみ）
        map["〜"] = "~"
        map["ー"] = "-"
        map["－"] = "-"
        map["‐"] = "-"
        map["―"] = "-"
        map["–"] = "-"
        map["—"] = "-"

        // 読点・句点はコード中では区切り記号として使われることが多い。
        map["、"] = ","
        map["。"] = "."

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
        String(text.map { table[$0] ?? $0 })
    }
}
