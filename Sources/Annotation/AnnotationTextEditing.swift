import Foundation

// テキスト編集を確定したときの扱いを決める純粋関数。
//
// 画面（NSTextView・キャンバス）から「空なら作らない」「変わっていなければ履歴を
// 積まない」の判断を切り出して、画面なしでテストできるようにしてある。
enum AnnotationTextEditing {

    /// 確定したときにドキュメントへ行う操作。
    enum Outcome: Equatable {
        /// 何もしない（新規で空 / 既存で内容が変わっていない）。
        case none
        /// 新しいテキスト注釈を作る。
        case create(String)
        /// 既存のテキストを書き換える。
        case update(String)
        /// 既存のテキストを空にしたので削除する。
        case delete
    }

    /// 確定する文字列の整え方。末尾の空の行・空白だけの行は、見えないのに外接矩形
    /// （選択枠・当たり判定）だけ広げてしまうので落とす（最後の文字行の末尾の空白は残す）。
    /// 先頭や途中の空行は意図して入れたものなので残す。
    static func normalized(_ text: String) -> String {
        // 改行は Character 単位で見る（"\r\n" を 1 つの改行として扱う）。
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// 空とみなすか。空白・改行だけでも、画像には何も出ないので空として扱う。
    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// - Parameters:
    ///   - original: 編集を始めた既存のテキスト注釈。新規なら nil。
    ///   - editedText: 確定時の文字列。
    static func outcome(original: Annotation?, editedText: String) -> Outcome {
        let text = normalized(editedText)
        let empty = isEmpty(text)
        guard let original else {
            return empty ? .none : .create(text)
        }
        if empty { return .delete }
        return text == original.text ? .none : .update(text)
    }
}
