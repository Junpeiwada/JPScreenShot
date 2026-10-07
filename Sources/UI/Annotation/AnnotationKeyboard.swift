import AppKit

// キャンバスがキーボードで受ける操作の判定だけを切り出した純粋関数。
//
// NSEvent から keyCode・文字・修飾キーだけを取り出して渡せば、画面なしでテストできる。
// 「キャンバスが first responder のときだけ」「テキスト編集中は無効」の判断は
// 呼び出し側（AnnotationCanvasView）が行う。ここは「このキーは何の操作か」だけを返す。
enum AnnotationKeyboard {

    /// キーに対応する操作。
    enum Command: Equatable {
        /// ツールを切り替える（V A L R O T B M）。
        case selectTool(AnnotationTool)
        /// 選択中を動かす。単位は画像のポイント。
        case nudge(dx: CGFloat, dy: CGFloat)
        /// 選択中を削除する（⌫・forward delete）。
        case delete
        /// Esc。
        case escape
    }

    /// 通常の矢印キーの移動量（ポイント）。
    static let nudgeStep: CGFloat = 1
    /// Shift を押したときの移動量（ポイント）。
    static let nudgeStepLarge: CGFloat = 10

    // keyCode
    private static let escapeKey: UInt16 = 53
    private static let deleteKey: UInt16 = 51
    private static let forwardDeleteKey: UInt16 = 117
    private static let leftKey: UInt16 = 123
    private static let rightKey: UInt16 = 124
    private static let downKey: UInt16 = 125
    private static let upKey: UInt16 = 126

    /// 1 文字ショートカットとツールの対応表（大文字で表示する）。
    /// 判定（`tool(forCharacter:)`）とツールチップ（`shortcutKey(for:)`）の両方がここを引くので、
    /// 実際のキーと表示がずれない。
    private static let toolKeys: [(key: String, tool: AnnotationTool)] = [
        ("V", .select), ("A", .arrow), ("L", .line), ("R", .rect),
        ("O", .ellipse), ("T", .text), ("B", .blur), ("M", .mosaic),
    ]

    /// 1 文字ショートカットとツールの対応（大文字・小文字を区別しない）。
    static func tool(forCharacter character: String) -> AnnotationTool? {
        let upper = character.uppercased()
        return toolKeys.first { $0.key == upper }?.tool
    }

    /// ツールのショートカットキー（表示用の大文字 1 文字）。
    static func shortcutKey(for tool: AnnotationTool) -> String? {
        toolKeys.first { $0.tool == tool }?.key
    }

    /// キーの操作を決める。割り当てが無ければ nil。
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`。
    ///   - characters: `NSEvent.charactersIgnoringModifiers`。
    ///   - modifiers: 修飾キー。
    /// - 文字キー（ツール切り替え）は修飾キーなしのときだけ。Shift も不可
    ///   （Shift+文字は将来の別操作のために空けておく）。
    /// - 矢印キーは ⌘・⌥・⌃ なしのときだけ。Shift で 10pt。
    static func command(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Command? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let onlyShift = flags.subtracting(.shift).isEmpty

        switch keyCode {
        case escapeKey:
            return flags.isEmpty ? .escape : nil
        case deleteKey, forwardDeleteKey:
            return flags.isEmpty ? .delete : nil
        case leftKey, rightKey, downKey, upKey:
            guard onlyShift else { return nil }
            let step = flags.contains(.shift) ? nudgeStepLarge : nudgeStep
            switch keyCode {
            case leftKey: return .nudge(dx: -step, dy: 0)
            case rightKey: return .nudge(dx: step, dy: 0)
            case downKey: return .nudge(dx: 0, dy: step)  // 注釈座標は y 下向き
            default: return .nudge(dx: 0, dy: -step)
            }
        default:
            break
        }

        guard flags.isEmpty, let characters, characters.count == 1,
            let tool = tool(forCharacter: characters)
        else { return nil }
        return .selectTool(tool)
    }

    /// 「閉じる」ボタンに Esc（`.cancelAction`）を持たせるか。
    ///
    /// キャンバスが Esc を先に受けたい場面（テキスト編集中の確定、キャンバスにフォーカスが
    /// ある状態での選択解除）では外す。付けたままだと SwiftUI が先に受けて閉じてしまう。
    /// OCR テキスト欄などキャンバス以外にフォーカスがあるときは、選択の有無によらず付ける
    /// （従来どおり Esc で閉じる）。
    static func closeButtonOwnsEscape(
        isEditingText: Bool, isCanvasFocused: Bool, hasSelection: Bool
    ) -> Bool {
        if isEditingText { return false }
        if isCanvasFocused && hasSelection { return false }
        return true
    }
}
