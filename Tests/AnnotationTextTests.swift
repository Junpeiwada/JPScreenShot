import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// テキスト注釈（外接矩形・拡縮・確定時の扱い）。すべて純粋関数で、画面権限は要らない。
@Suite("テキスト注釈")
struct AnnotationTextTests {

    private func text(_ string: String, size: Double = 24, at origin: CGPoint = CGPoint(x: 20, y: 30))
        -> Annotation
    {
        var style = AnnotationStyle()
        style.text.size = size
        return Annotation(kind: .text, start: origin, end: origin, text: string, style: style)
    }

    // MARK: 外接矩形

    @Test("外接矩形は文字の左上を原点に、測った大きさを持つ")
    func 外接矩形() {
        let a = text("Hello")
        let bounds = AnnotationGeometry.bounds(of: a)
        let measured = AnnotationTextLayout.size(of: "Hello", style: a.style.text)
        #expect(bounds.origin == a.start)
        #expect(bounds.size == measured)
        #expect(bounds.width > 0 && bounds.height > 0)
    }

    @Test("複数行は行数に応じて高さが増え、幅は最長の行")
    func 複数行() {
        let one = AnnotationGeometry.bounds(of: text("abc"))
        let two = AnnotationGeometry.bounds(of: text("abc\nabcdef"))
        #expect(two.height > one.height * 1.8)
        #expect(two.width > one.width)
        // 最後に改行を足すと空行ぶん高くなる（編集中の入力欄と同じ測り方）。
        let trailing = AnnotationGeometry.bounds(of: text("abc\n"))
        #expect(trailing.height > one.height * 1.8)
    }

    @Test("空文字でも外接矩形は 1pt 以上（当たり判定・ハンドルが潰れない）")
    func 空文字() {
        let bounds = AnnotationGeometry.bounds(of: text(""))
        #expect(bounds.width >= 1 && bounds.height >= 1)
    }

    @Test("テキストの当たり判定は外接矩形（許容幅つき）")
    func 当たり判定() {
        let a = text("Hello")
        let b = AnnotationGeometry.bounds(of: a)
        #expect(AnnotationGeometry.hitTest(a, at: CGPoint(x: b.midX, y: b.midY), tolerance: 2))
        #expect(!AnnotationGeometry.hitTest(a, at: CGPoint(x: b.maxX + 20, y: b.midY), tolerance: 2))
    }

    // MARK: 拡縮

    @Test("角ハンドルを 2 倍に引くと文字サイズも約 2 倍になり、反対の角は動かない")
    func 拡縮で文字サイズが比例() {
        let a = text("Hello", size: 20)
        let b = AnnotationGeometry.bounds(of: a)
        // 右下ハンドルを、左上からの距離が 2 倍になる位置へ。
        let target = CGPoint(x: b.minX + b.width * 2, y: b.minY + b.height * 2)
        let resized = AnnotationGeometry.resized(a, handle: .bottomRight, to: target)
        #expect(abs(resized.style.text.size - 40) < 0.001)
        let nb = AnnotationGeometry.bounds(of: resized)
        // 左上は固定。
        #expect(abs(nb.minX - b.minX) < 0.001 && abs(nb.minY - b.minY) < 0.001)
        // 外接矩形の大きさもほぼ 2 倍（フォントの丸めぶんは許す）。
        #expect(abs(nb.width / b.width - 2) < 0.1)
        #expect(abs(nb.height / b.height - 2) < 0.1)
    }

    @Test("左上ハンドルで縮めると右下が固定される")
    func 左上で縮小() {
        let a = text("Hello", size: 40)
        let b = AnnotationGeometry.bounds(of: a)
        let target = CGPoint(x: b.maxX - b.width * 0.5, y: b.maxY - b.height * 0.5)
        let resized = AnnotationGeometry.resized(a, handle: .topLeft, to: target)
        #expect(abs(resized.style.text.size - 20) < 0.001)
        let nb = AnnotationGeometry.bounds(of: resized)
        #expect(abs(nb.maxX - b.maxX) < 0.001 && abs(nb.maxY - b.maxY) < 0.001)
    }

    @Test("極端に小さく引いても文字サイズは下限（4pt）を下回らない")
    func 拡縮の下限() {
        let a = text("Hello", size: 20)
        let b = AnnotationGeometry.bounds(of: a)
        let resized = AnnotationGeometry.resized(
            a, handle: .bottomRight, to: CGPoint(x: b.minX - 100, y: b.minY - 100))
        #expect(resized.style.text.size == 4)
    }

    @Test("テキストのハンドルは外接矩形の 8 点")
    func ハンドル() {
        let a = text("Hello")
        #expect(AnnotationGeometry.handles(of: a).count == 8)
    }

    // MARK: 確定時の扱い

    @Test("新規で空なら何も作らない（空白・改行だけも同じ）")
    func 新規の空は作らない() {
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "") == .none)
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "  \n \n") == .none)
    }

    @Test("新規で文字があれば作る。末尾の改行は落とす")
    func 新規は作る() {
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "abc") == .create("abc"))
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "a\nb\n\n") == .create("a\nb"))
        // 先頭・途中の空行は意図して入れたものなので残す。
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "\na") == .create("\na"))
    }

    @Test("末尾の空白だけの行も落とす（途中・先頭は残す）")
    func 末尾の空白行() {
        #expect(AnnotationTextEditing.normalized("a\n  \n\t") == "a")
        #expect(AnnotationTextEditing.normalized("a\n \nb\n   ") == "a\n \nb")
        #expect(AnnotationTextEditing.normalized("  \na") == "  \na")
        #expect(AnnotationTextEditing.outcome(original: nil, editedText: "a\n   ") == .create("a"))
        #expect(AnnotationTextEditing.outcome(original: text("a"), editedText: "a\n  \n") == .none)
    }

    @Test("既存を空にしたら削除、変えなければ何もしない、変えたら更新")
    func 既存の編集() {
        let original = text("abc")
        #expect(AnnotationTextEditing.outcome(original: original, editedText: "") == .delete)
        #expect(AnnotationTextEditing.outcome(original: original, editedText: " \n") == .delete)
        #expect(AnnotationTextEditing.outcome(original: original, editedText: "abc") == .none)
        #expect(AnnotationTextEditing.outcome(original: original, editedText: "abc\n") == .none)
        #expect(AnnotationTextEditing.outcome(original: original, editedText: "abcd") == .update("abcd"))
    }

    // MARK: ドキュメントでの確定（取り消し 1 回分）

    @MainActor
    @Test("テキストの追加・更新・削除はそれぞれ取り消し 1 回で戻る")
    func 確定は取り消し1回() {
        let document = AnnotationDocument()
        var a = text("abc")
        a.text = "abc"
        document.add(a, select: true)
        #expect(document.undoStack.count == 1)

        document.mutate(ids: [a.id]) { $0.text = "abcd" }
        #expect(document.undoStack.count == 2)
        #expect(document.annotation(id: a.id)?.text == "abcd")

        document.undo()
        #expect(document.annotation(id: a.id)?.text == "abc")

        document.remove(ids: [a.id])
        #expect(document.annotations.isEmpty)
        document.undo()
        #expect(document.annotations.count == 1)
    }

    // MARK: 描画

    @MainActor
    @Test("複数行の縁取りでも、すべての行の文字色が縁に隠れない")
    func 縁の上に文字() throws {
        // 2 行・太い縁の白文字を描き、文字の内側（白）の画素が残っていることを確かめる。
        var a = text("HH\nHH", size: 40, at: CGPoint(x: 10, y: 10))
        a.style.text.color = .white
        a.style.text.outline = OutlineStyle(isOn: true, color: .black, width: 6)
        let base = try #require(makeImage(width: 140, height: 140))
        let result = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [a]))
        let data = try #require(result.dataProvider?.data) as Data
        // 白に近い画素が一定数ある（文字が縁で塗りつぶされていない）。
        let bytesPerRow = result.bytesPerRow
        var white = 0
        var black = 0
        for y in 0..<result.height {
            for x in 0..<result.width {
                let i = y * bytesPerRow + x * 4
                if data[i] > 240, data[i + 1] > 240, data[i + 2] > 240 { white += 1 }
                if data[i] < 15, data[i + 1] < 15, data[i + 2] < 15, data[i + 3] > 240 { black += 1 }
            }
        }
        // 土台は透明な黒ではなく不透明な灰にしているので、黒は縁だけ。
        #expect(white > 200)
        #expect(black > 200)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
