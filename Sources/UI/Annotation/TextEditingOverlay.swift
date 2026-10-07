import AppKit

// テキスト注釈を入力・編集するときに、キャンバスの上へ重ねる NSTextView。
//
// 文字の見た目（フォント・サイズ・色）は注釈のスタイルを表示倍率込みで合わせる。
//
// ★縁取りの見た目について（決めた方法）:
// NSTextView の描画で袋文字の縁を再現するのは難しい。`.strokeWidth` 属性は
// 輪郭の内外へ半分ずつ線を引くだけで、レンダラの「縁を先に塗ってから文字を上に
// 塗る」（外側へだけ張り出す）にならず、文字が痩せて読みにくくなる。
// そこで編集中は**縁なしの文字**にし、背景に**文字色の明るさに応じた半透明の座布団**
// を敷く（明るい文字には暗い座布団、暗い文字には明るい座布団）。白文字を白い座布団に
// 乗せると読めなくなるため、固定の白にはしていない。確定すると縁付きの描画に戻る。

/// 編集中のテキストビュー。確定の操作（`Esc`・⌘Return・フォーカスが外れる）を通知する。
@MainActor
final class AnnotationTextView: NSTextView {

    /// `Esc` または ⌘Return が押された。
    var onCommit: (() -> Void)?
    /// 文字列が変わった（大きさの追従用）。
    var onTextChange: (() -> Void)?
    /// フォーカスを失った（外のクリックなど）。
    var onResign: (() -> Void)?

    /// 入力欄専用の取り消し履歴。ウィンドウの UndoManager を共有すると、OCR テキスト欄の
    /// ⌘Z と履歴が混ざる。入力中の ⌘Z は、この欄の中の取り消しだけにする。
    private let localUndoManager = UndoManager()
    override var undoManager: UndoManager? { localUndoManager }

    // TextKit 1 で作る（TextKit 2 は layoutManager に触れると TextKit 1 へ
    // 切り替わる。大きさはレンダラと同じ AnnotationTextLayout で測るので不要だが、
    // 挙動を固定しておく）。
    convenience init() {
        self.init(usingTextLayoutManager: false)
    }

    override func keyDown(with event: NSEvent) {
        // 日本語変換中の Return・Esc は入力メソッドが先に受ける（ここへは来ない）が、
        // 念のため変換中は確定処理を走らせない。
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if !hasMarkedText(), isReturn, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    /// `Esc`。変換中は変換の取り消しに使われるので何もしない。
    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        onCommit?()
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}

/// テキスト編集の見た目の決め事（純粋な部分）。
enum TextEditingAppearance {

    /// 編集中の座布団の色。文字色が明るければ暗く、暗ければ明るく。
    static func cushionColor(for text: RGBAColor) -> NSColor {
        // 相対輝度の簡易値（sRGB のまま重み付け）。0.5 を境に切り替える。
        let luminance = 0.299 * text.red + 0.587 * text.green + 0.114 * text.blue
        return luminance > 0.5
            ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 1, alpha: 0.75)
    }

    /// 文字が欠けないよう、測った幅に足す余白（ポイント）。入力のたびに枠を測り直すので
    /// 小さくてよいが、キャレットが枠の外へ出ないようにする。
    static let widthPadding: CGFloat = 12
}

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
