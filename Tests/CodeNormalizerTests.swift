import Testing

@testable import JPScreenShot

// CodeNormalizer は純粋関数なので、画面もキャプチャ権限も不要でテストできる。
// 「日本語を壊さない」ことが最も壊れやすいので重点的に固定する。
@Suite("コードモードの全角→半角正規化")
struct CodeNormalizerTests {

    @Test("全角の記号・英数字を半角に直す", arguments: [
        ("ｉｆ（ｘ）｛ｒｅｔｕｒｎ；｝", "if(x){return;}"),
        ("arr［０］＝１；", "arr[0]=1;"),
        ("a＋b－c＊d／e", "a+b-c*d/e"),
        ("ｘ＝１～２", "x=1~2"),
        ("ａ＆＆ｂ｜｜ｃ", "a&&b||c"),
        ("＃include＜stdio＞", "#include<stdio>"),
    ])
    func 全角記号を半角にする(input: String, expected: String) {
        #expect(CodeNormalizer.normalize(input) == expected)
    }

    @Test("全角空白を半角にする")
    func 全角空白() {
        #expect(CodeNormalizer.normalize("\u{3000}x") == " x")
    }

    // ここが本題。長音記号・読点・句点を無条件に変換すると
    // `サーバーエラー` が `サ-バ-エラ-` になって日本語が壊れる。
    @Test("日本語の長音・読点・句点は壊さない", arguments: [
        "// データーベース接続、失敗。",
        "let メッセージ = \"サーバーエラー\"",
        "// ユーザーインターフェース",
        "// コピー不可のPDFやレンダラー",
        "テーブル、ビュー、コントローラー。",
    ])
    func 日本語を壊さない(text: String) {
        #expect(CodeNormalizer.normalize(text) == text)
    }

    @Test("日本語でない文脈では長音・読点も記号として直す", arguments: [
        ("a ー b", "a - b"),
        ("1、2、3", "1,2,3"),
        ("end。", "end."),
    ])
    func 記号の文脈では変換する(input: String, expected: String) {
        #expect(CodeNormalizer.normalize(input) == expected)
    }

    // 仕様 6.3: 字形の混同は自動補正しない（文脈がないと判断できず、
    // 正しい文字を壊す危険があるため）。
    @Test("字形の混同は補正しない")
    func 字形の混同は放置する() {
        // `88` を `&&` に戻したり `1` を `l` に戻したりしてはいけない。
        let input = "if (1 == 1 88 0 != 0)"
        #expect(CodeNormalizer.normalize(input) == input)
    }

    @Test("変換対象がなければそのまま返す")
    func 変換不要なら不変() {
        let input = "let x = foo(bar) // comment"
        #expect(CodeNormalizer.normalize(input) == input)
    }

    @Test("空文字列を扱える")
    func 空文字列() {
        #expect(CodeNormalizer.normalize("") == "")
    }
}
