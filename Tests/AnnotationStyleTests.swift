import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// スタイルの保存・色と太さの効き先・ぼかしの強さの下限（フェーズ 4）。
@Suite("注釈のスタイル")
struct AnnotationStyleTests {

    /// テスト専用の UserDefaults。実際の設定を汚さない。
    private func makeStore() -> (AnnotationStyleStore, UserDefaults) {
        let name = "AnnotationStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (AnnotationStyleStore(defaults: defaults), defaults)
    }

    @MainActor
    private func makeEditor(store: AnnotationStyleStore) -> AnnotationEditor {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return AnnotationEditor(base: context.makeImage()!, scale: 1, styleStore: store)
    }

    private func annotation(_ kind: AnnotationKind, style: AnnotationStyle? = nil) -> Annotation {
        Annotation(
            kind: kind, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 40),
            text: kind == .text ? "abc" : "",
            style: style ?? .initialStyle(for: kind))
    }

    // MARK: 保存（P4-4）

    @Test("スタイルを JSON で保存して読むと、種類ごとに一致する")
    func 保存の往復() {
        let (store, _) = makeStore()
        var rect = AnnotationStyle.initialStyle(for: .rect)
        rect.color = RGBAColor(hex: 0x007AFF)
        rect.lineWidth = 9
        rect.fill = .translucent
        var text = AnnotationStyle.initialStyle(for: .text)
        text.text.fontName = "HelveticaNeue"
        text.text.weight = .heavy
        text.text.size = 48
        text.text.outline = OutlineStyle(isOn: true, color: RGBAColor(hex: 0xFF3B30), width: 5)
        store.save(rect, for: .rect)
        store.save(text, for: .text)

        #expect(store.style(for: .rect) == rect)
        #expect(store.style(for: .text) == text)
        // 保存していない種類は nil（呼び出し側が初期値を使う）。
        #expect(store.style(for: .arrow) == nil)
        // 別のインスタンスでも同じ UserDefaults から読める（再起動の代わり）。
        #expect(AnnotationStyleStore(defaults: store.defaults).style(for: .text) == text)
    }

    @Test("壊れた保存値は無視して空を返す")
    func 壊れた保存値() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: AnnotationStyleStore.key)
        #expect(store.loadAll().isEmpty)
    }

    @Test("AnnotationStyle 単体も JSON で往復する")
    func スタイルのJSON往復() throws {
        var style = AnnotationStyle.initialStyle(for: .arrow)
        style.arrowHeads = .both
        style.dash = .dashed
        style.shadow = ShadowStyle(isOn: true, blur: 7, distance: 3)
        style.redaction = RedactionStyle(strength: 20, shape: .ellipse)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == style)
    }

    @MainActor
    @Test("エディタは保存済みのスタイルを新規作成の初期値にする")
    func 初期値は最後のスタイル() {
        let (store, _) = makeStore()
        var saved = AnnotationStyle.initialStyle(for: .ellipse)
        saved.lineWidth = 9
        store.save(saved, for: .ellipse)
        let editor = makeEditor(store: store)
        #expect(editor.style(for: .ellipse) == saved)
        // 保存していない種類は初期値。テキストは影なし、他は影あり。
        #expect(editor.style(for: .rect) == .initialStyle(for: .rect))
        #expect(!editor.style(for: .text).shadow.isOn)
        #expect(editor.style(for: .arrow).shadow.isOn)
    }

    // MARK: 色・太さ（P4-1）

    @MainActor
    @Test("選択中の色変更は取り消し 1 回で戻り、その種類の最後のスタイルも更新される")
    func 選択中の色変更() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        let a = annotation(.rect)
        editor.document.add(a)
        let blue = RGBAColor(hex: 0x007AFF)

        editor.setColor(blue)
        #expect(editor.document.annotation(id: a.id)?.style.color == blue)
        #expect(editor.document.undoStack.count == 2)  // 追加 + 色変更
        #expect(editor.style(for: .rect).color == blue)
        editor.flushStyles()
        #expect(store.style(for: .rect)?.color == blue)

        editor.document.undo()
        #expect(editor.document.annotation(id: a.id)?.style.color == a.style.color)
    }

    @MainActor
    @Test("テキストでは色が文字色に効き、太さは無視される")
    func テキストの色と太さ() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        let t = annotation(.text)
        editor.document.add(t)
        let before = editor.document.annotation(id: t.id)!.style

        editor.setColor(RGBAColor(hex: 0xFFCC00))
        let after = editor.document.annotation(id: t.id)!.style
        #expect(after.text.color == RGBAColor(hex: 0xFFCC00))
        #expect(after.color == before.color)  // 線の色は触らない

        let count = editor.document.undoStack.count
        editor.setLineWidth(9)
        #expect(editor.document.annotation(id: t.id)?.style.lineWidth == before.lineWidth)
        #expect(editor.document.undoStack.count == count)  // 変化なし＝履歴を積まない
        #expect(!editor.canChangeLineWidth)
        #expect(editor.canChangeColor)
    }

    @MainActor
    @Test("ぼかしには色も太さも効かない")
    func ぼかしは色も太さも無し() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        editor.document.add(annotation(.blur))
        #expect(!editor.canChangeColor)
        #expect(!editor.canChangeLineWidth)
        #expect(editor.displayedColor == nil)
    }

    @MainActor
    @Test("選択が無ければ、描画ツールの種類の最後のスタイルに効く")
    func 選択なしは次に描くものへ() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        editor.selectTool(.rect)
        editor.setColor(RGBAColor(hex: 0x34C759))
        editor.setLineWidth(3)
        #expect(editor.style(for: .rect).color == RGBAColor(hex: 0x34C759))
        #expect(editor.style(for: .rect).lineWidth == 3)
        // 他の種類は変わらない。
        #expect(editor.style(for: .arrow).color == AnnotationStyle.initialStyle(for: .arrow).color)
        #expect(editor.document.undoStack.isEmpty)
        #expect(editor.displayedColor == RGBAColor(hex: 0x34C759))
    }

    @MainActor
    @Test("選択ツールで何も選んでいなければテキスト以外の全種類に効く")
    func 選択ツールの色はテキスト以外() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        editor.setColor(RGBAColor(hex: 0x007AFF))
        #expect(editor.style(for: .arrow).color == RGBAColor(hex: 0x007AFF))
        #expect(editor.style(for: .ellipse).color == RGBAColor(hex: 0x007AFF))
        #expect(editor.style(for: .text).text.color == TextStyle().color)  // 白文字のまま
    }

    @MainActor
    @Test("連続した色変更（カラーパネル）は取り消し 1 回にまとまる")
    func 連続変更はまとめる() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        let a = annotation(.rect)
        editor.document.add(a)
        let base = editor.document.undoStack.count
        for i in 0..<20 {
            editor.setColor(RGBAColor(red: Double(i) / 20, green: 0, blue: 0), coalescing: "railColor")
        }
        #expect(editor.document.undoStack.count == base + 1)
        editor.document.undo()
        #expect(editor.document.annotation(id: a.id)?.style.color == a.style.color)
    }

    @MainActor
    @Test("スライダーのドラッグは開始〜終了で取り消し 1 回")
    func スライダーは1回() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        let a = annotation(.rect)
        editor.document.add(a)
        let base = editor.document.undoStack.count

        editor.beginContinuousStyleChange()
        for width in stride(from: 6.0, through: 20.0, by: 1.0) {
            editor.updateStyle { style, _ in style.lineWidth = width }
        }
        editor.endContinuousStyleChange()
        #expect(editor.document.undoStack.count == base + 1)
        #expect(editor.document.annotation(id: a.id)?.style.lineWidth == 20)
        // 最後の値が種類の最後のスタイルになる。
        #expect(editor.style(for: .rect).lineWidth == 20)

        // 何も変えずに離したら履歴を積まない。
        editor.beginContinuousStyleChange()
        editor.endContinuousStyleChange()
        #expect(editor.document.undoStack.count == base + 1)
    }

    @Test("プリセットは赤・黄・緑・青・黒・白の 6 色、太さは 3・5・9")
    func プリセット() {
        let hexes = AnnotationStyleEditing.presetColors
        #expect(hexes.count == 6)
        #expect(hexes[0] == RGBAColor(hex: 0xFF3B30))
        #expect(hexes[4] == .black && hexes[5] == .white)
        #expect(AnnotationStyleEditing.Thickness.allCases.map(\.points) == [3, 5, 9])
        #expect(RGBAColor(hex: 0x007AFF).isClose(to: RGBAColor(red: 0, green: 122.0 / 255, blue: 1)))
        #expect(!RGBAColor.red.isClose(to: .blue))
    }

    // MARK: 種類変更（P4-3）

    @MainActor
    @Test("種類の切り替えは取り消し 1 回で、切り替え後の種類の最後のスタイルになる")
    func 種類変更() {
        let (store, _) = makeStore()
        let editor = makeEditor(store: store)
        let a = annotation(.rect)
        editor.document.add(a)
        let base = editor.document.undoStack.count
        editor.changeKind(to: .ellipse)
        #expect(editor.document.annotation(id: a.id)?.kind == .ellipse)
        #expect(editor.document.undoStack.count == base + 1)
        editor.flushStyles()
        #expect(store.style(for: .ellipse) != nil)
        editor.document.undo()
        #expect(editor.document.annotation(id: a.id)?.kind == .rect)
    }

    // MARK: ぼかし・モザイクの強さ（P4-5）

    @Test("強さの範囲はぼかし 6pt 以上・モザイク 8pt 以上")
    func 強さの範囲() {
        #expect(RedactionStyle.strengthRange(for: .blur).lowerBound == 6)
        #expect(RedactionStyle.strengthRange(for: .mosaic).lowerBound == 8)
        #expect(RedactionStyle.strengthRange(for: .blur).upperBound == RedactionStyle.maximumStrength)
        #expect(RedactionStyle(strength: 1).clamped(for: .blur).strength == 6)
        #expect(RedactionStyle(strength: 1).clamped(for: .mosaic).strength == 8)
        #expect(RedactionStyle(strength: 999).clamped(for: .blur).strength == 40)
        #expect(RedactionStyle(strength: 12).clamped(for: .mosaic).strength == 12)
    }

    @MainActor
    @Test("ドキュメントは下限未満の強さを受け付けない（追加・書き換え・種類変更）")
    func ドキュメントでの下限() {
        let document = AnnotationDocument()
        var blur = annotation(.blur)
        blur.style.redaction.strength = 1
        document.add(blur)
        #expect(document.annotation(id: blur.id)?.style.redaction.strength == 6)

        document.mutate(ids: [blur.id]) { $0.style.redaction.strength = 2 }
        #expect(document.annotation(id: blur.id)?.style.redaction.strength == 6)

        // ぼかし 6 をモザイクへ切り替えると、モザイクの下限 8 に引き上げられる。
        document.changeKind(to: .mosaic, ids: [blur.id])
        #expect(document.annotation(id: blur.id)?.style.redaction.strength == 8)

        var changed = document.annotation(id: blur.id)!
        changed.style.redaction.strength = 3
        document.setWithoutHistory(changed)
        #expect(document.annotation(id: blur.id)?.style.redaction.strength == 8)
    }

    // MARK: カラーパネルのガード

    @Test("色がばらばらの複数選択では、先頭と同じ色を選んでも適用する")
    func ピッカーはばらばらなら適用() {
        let red = RGBAColor.red, blue = RGBAColor.blue
        #expect(AnnotationStyleEditing.shouldAcceptPickerColor(
            red, currentColors: [red, blue], secondsSinceSelectionChange: 10))
        // 全員がその色なら何もしない。
        #expect(!AnnotationStyleEditing.shouldAcceptPickerColor(
            red, currentColors: [red, red], secondsSinceSelectionChange: 10))
        // 対象が無い（色を持たない）ときは時間だけで判定。
        #expect(AnnotationStyleEditing.shouldAcceptPickerColor(
            red, currentColors: [], secondsSinceSelectionChange: 10))
    }

    @Test("微調整（わずかな色の差）は捨てない。選択直後の変更は捨てる")
    func ピッカーの微調整と直後() {
        let base = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        let nudged = RGBAColor(red: 0.505, green: 0.5, blue: 0.5)  // 0.01 未満の差
        #expect(AnnotationStyleEditing.shouldAcceptPickerColor(
            nudged, currentColors: [base], secondsSinceSelectionChange: 10))
        #expect(!AnnotationStyleEditing.shouldAcceptPickerColor(
            RGBAColor.blue, currentColors: [base], secondsSinceSelectionChange: 0.05))
    }
}
