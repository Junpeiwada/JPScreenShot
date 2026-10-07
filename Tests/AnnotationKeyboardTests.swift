import AppKit
import Testing

@testable import JPScreenShot

// キャンバスのキー判定（ツール切り替え・矢印移動・Esc の行き先）は純粋関数。
@Suite("注釈キャンバスのキー操作")
struct AnnotationKeyboardTests {

    private func command(_ key: UInt16, _ chars: String? = nil, _ mods: NSEvent.ModifierFlags = [])
        -> AnnotationKeyboard.Command?
    {
        AnnotationKeyboard.command(keyCode: key, characters: chars, modifiers: mods)
    }

    @Test("V A L R O T B M が各ツールに対応する（大文字でも同じ）")
    func ツールの文字() {
        let table: [(String, AnnotationTool)] = [
            ("v", .select), ("a", .arrow), ("l", .line), ("r", .rect),
            ("o", .ellipse), ("t", .text), ("b", .blur), ("m", .mosaic),
        ]
        for (character, tool) in table {
            #expect(command(0, character) == .selectTool(tool))
            #expect(AnnotationKeyboard.tool(forCharacter: character.uppercased()) == tool)
        }
        // 全ツールが割り当てられている。
        #expect(Set(table.map(\.1)) == Set(AnnotationTool.allCases))
        // ツールチップのキー表示は判定と同じ対応表から引く（ずれない）。
        for (character, tool) in table {
            #expect(AnnotationKeyboard.shortcutKey(for: tool) == character.uppercased())
        }
        #expect(AnnotationTool.arrow.helpText == "矢印（A）")
    }

    @Test("修飾キーがあるとツール切り替えにならない（⌘A などを奪わない）")
    func 修飾キーで無効() {
        #expect(command(0, "a", .command) == nil)
        #expect(command(0, "a", .option) == nil)
        #expect(command(0, "a", .control) == nil)
        #expect(command(0, "a", .shift) == nil)
        // CapsLock は修飾とみなさない。
        #expect(command(0, "a", .capsLock) == .selectTool(.arrow))
    }

    @Test("割り当てのない文字は無視する")
    func 他の文字() {
        #expect(command(6, "z") == nil)
        #expect(command(0, "ab") == nil)
        #expect(command(0, nil) == nil)
    }

    @Test("矢印キーは 1pt、Shift で 10pt。上は y が負（注釈座標は下向き）")
    func 矢印キー() {
        #expect(command(123) == .nudge(dx: -1, dy: 0))
        #expect(command(124) == .nudge(dx: 1, dy: 0))
        #expect(command(125) == .nudge(dx: 0, dy: 1))
        #expect(command(126) == .nudge(dx: 0, dy: -1))
        #expect(command(124, nil, .shift) == .nudge(dx: 10, dy: 0))
        #expect(command(126, nil, .shift) == .nudge(dx: 0, dy: -10))
        // 矢印キーは .function / .numericPad が付くことがあるが無視する。
        #expect(command(123, nil, [.function, .numericPad]) == .nudge(dx: -1, dy: 0))
        #expect(command(123, nil, .command) == nil)
        #expect(command(123, nil, .option) == nil)
    }

    @Test("⌫・forward delete は削除、Esc は escape")
    func 削除とEsc() {
        #expect(command(51) == .delete)
        #expect(command(117) == .delete)
        #expect(command(53) == .escape)
        #expect(command(51, nil, .command) == nil)
    }

    @Test("Esc の行き先: 入力中・キャンバスで選択ありのときは閉じるボタンが持たない")
    func Escの行き先() {
        func owns(_ editing: Bool, _ focused: Bool, _ selected: Bool) -> Bool {
            AnnotationKeyboard.closeButtonOwnsEscape(
                isEditingText: editing, isCanvasFocused: focused, hasSelection: selected)
        }
        #expect(!owns(true, true, false))
        #expect(!owns(true, false, true))
        #expect(!owns(false, true, true))
        // 選択なし → 閉じる。
        #expect(owns(false, true, false))
        // OCR 欄などキャンバス以外にフォーカス → 選択があっても閉じる。
        #expect(owns(false, false, true))
        #expect(owns(false, false, false))
    }
}
