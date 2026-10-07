import CoreGraphics
import Foundation
import Testing

@testable import JPScreenShot

// 取り消し・やり直し、層ごとの重なり順、複製、種類変更の確認。
@MainActor
@Suite("注釈ドキュメント")
struct AnnotationDocumentTests {

    private func make(_ kind: AnnotationKind, at x: CGFloat = 0) -> Annotation {
        Annotation(kind: kind, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + 50, y: 50))
    }

    @Test("追加 → 取り消し → やり直しで配列が元に戻る")
    func 取り消しとやり直し() {
        let doc = AnnotationDocument()
        #expect(!doc.canUndo && !doc.canRedo)

        let a = make(.rect)
        doc.add(a)
        #expect(doc.annotations == [a])
        #expect(doc.selectedIDs == [a.id])
        #expect(doc.canUndo)

        doc.undo()
        #expect(doc.annotations.isEmpty)
        #expect(doc.selectedIDs.isEmpty)  // 消えた注釈の選択は外れる
        #expect(doc.canRedo)

        doc.redo()
        #expect(doc.annotations == [a])
        #expect(!doc.canRedo)
    }

    @Test("新しい操作をするとやり直しは破棄される")
    func やり直しの破棄() {
        let doc = AnnotationDocument()
        doc.add(make(.rect))
        doc.undo()
        #expect(doc.canRedo)
        doc.add(make(.line))
        #expect(!doc.canRedo)
    }

    @Test("ドラッグ中の更新は履歴に積まれず、開始時の 1 回だけ積まれる")
    func 連続変更() {
        let doc = AnnotationDocument()
        let a = make(.rect)
        doc.add(a)
        let before = doc.undoStack.count

        doc.beginChange()
        for i in 1...20 {
            var moved = a
            moved.start.x = CGFloat(i)
            doc.setWithoutHistory(moved)
        }
        doc.commitChange()
        #expect(doc.undoStack.count == before + 1)
        #expect(doc.annotation(id: a.id)?.start.x == 20)

        // 1 回の取り消しでドラッグ前に戻る。
        doc.undo()
        #expect(doc.annotation(id: a.id)?.start.x == 0)
    }

    @Test("変化のないドラッグ（ただのクリック）は履歴を増やさない")
    func 変化なしのコミット() {
        let doc = AnnotationDocument()
        doc.add(make(.rect))
        let before = doc.undoStack.count
        doc.beginChange()
        doc.commitChange()
        #expect(doc.undoStack.count == before)
    }

    @Test("mutate は複数件を 1 回の取り消しにまとめる")
    func まとめて変更() {
        let doc = AnnotationDocument()
        let a = make(.rect)
        let b = make(.ellipse)
        doc.add(a)
        doc.add(b)
        doc.select([a.id, b.id])
        doc.mutate { $0.style.lineWidth = 9 }
        #expect(doc.annotations.allSatisfy { $0.style.lineWidth == 9 })
        doc.undo()
        #expect(doc.annotations.allSatisfy { $0.style.lineWidth == 4 })
    }

    @Test("ぼかし層は図形層より後から追加しても手前に並ぶ")
    func 層の順序() {
        let doc = AnnotationDocument()
        let rect = make(.rect)
        let blur = make(.blur)
        let arrow = make(.arrow)
        let mosaic = make(.mosaic)
        doc.add(rect)
        doc.add(blur)
        doc.add(arrow)
        doc.add(mosaic)
        // 範囲加工層（blur, mosaic）が先、図形層（rect, arrow）が後。層内は追加順。
        #expect(doc.annotations.map(\.id) == [blur.id, mosaic.id, rect.id, arrow.id])
        #expect(doc.redactionAnnotations.map(\.id) == [blur.id, mosaic.id])
        #expect(doc.figureAnnotations.map(\.id) == [rect.id, arrow.id])
    }

    @Test("前面へ・背面へは同じ層の中だけで動く")
    func 前面と背面() {
        let doc = AnnotationDocument()
        let blur1 = make(.blur)
        let blur2 = make(.mosaic)
        let rect = make(.rect)
        let line = make(.line)
        for a in [blur1, blur2, rect, line] { doc.add(a) }

        // ぼかしを最前面にしても、図形層の手前（層の境目）で止まる。
        doc.bringToFront(ids: [blur1.id])
        #expect(doc.annotations.map(\.id) == [blur2.id, blur1.id, rect.id, line.id])

        // 図形を最背面にしても、ぼかし層の奥へは行かない。
        doc.sendToBack(ids: [line.id])
        #expect(doc.annotations.map(\.id) == [blur2.id, blur1.id, line.id, rect.id])

        // 複数選択は相対順を保つ。
        doc.sendToBack(ids: [blur1.id, blur2.id])
        #expect(doc.annotations.map(\.id) == [blur2.id, blur1.id, line.id, rect.id])
    }

    @Test("複製は新しい ID で少しずらし、複製側を選択する")
    func 複製() {
        let doc = AnnotationDocument()
        let a = make(.rect, at: 10)
        doc.add(a)
        let newIDs = doc.duplicate()
        #expect(newIDs.count == 1)
        #expect(doc.annotations.count == 2)
        let copy = doc.annotation(id: newIDs[0])!
        #expect(copy.id != a.id)
        #expect(copy.kind == .rect)
        #expect(copy.start == CGPoint(x: 20, y: 10))
        #expect(doc.selectedIDs == [copy.id])
        #expect(doc.annotation(id: a.id)?.start == a.start)  // 元は動かない
    }

    @Test("削除は選択中を消し、取り消しで戻る")
    func 削除() {
        let doc = AnnotationDocument()
        let a = make(.rect)
        let b = make(.line)
        doc.add(a)
        doc.add(b)
        doc.select([a.id])
        doc.remove()
        #expect(doc.annotations == [b])
        doc.undo()
        #expect(doc.annotations == [a, b])
    }

    @Test("種類変更は図形どうし・ぼかし⇔モザイクだけ許す")
    func 種類変更() {
        let doc = AnnotationDocument()
        let rect = make(.rect)
        let blur = make(.blur)
        let text = Annotation(kind: .text, start: .zero, end: .zero, text: "x")
        for a in [rect, blur, text] { doc.add(a) }

        doc.changeKind(to: .ellipse, ids: [rect.id])
        #expect(doc.annotation(id: rect.id)?.kind == .ellipse)
        doc.changeKind(to: .mosaic, ids: [blur.id])
        #expect(doc.annotation(id: blur.id)?.kind == .mosaic)
        // 位置と ID は保たれる。
        #expect(doc.annotation(id: blur.id)?.start == blur.start)

        // 層をまたぐ・テキストへの切り替えは無視される。
        doc.changeKind(to: .blur, ids: [rect.id])
        doc.changeKind(to: .rect, ids: [text.id])
        #expect(doc.annotation(id: rect.id)?.kind == .ellipse)
        #expect(doc.annotation(id: text.id)?.kind == .text)
    }

    @Test("線から矢印へ切り替えると先端が見える")
    func 線から矢印() {
        let doc = AnnotationDocument()
        var line = make(.line)
        line.style.arrowHeads = .none
        doc.add(line)
        doc.changeKind(to: .arrow, ids: [line.id])
        #expect(doc.annotation(id: line.id)?.style.arrowHeads == .end)
    }

    @Test("全消去で履歴も選択も空になる")
    func 全消去() {
        let doc = AnnotationDocument()
        doc.add(make(.rect))
        doc.removeAll()
        #expect(doc.annotations.isEmpty)
        #expect(doc.selectedIDs.isEmpty)
        #expect(!doc.canUndo && !doc.canRedo)
    }

    @Test("スタイルは Codable で往復しても一致する")
    func スタイルの保存() throws {
        var style = AnnotationStyle()
        style.color = .blue
        style.arrowHeads = .both
        style.text.fontName = "HelveticaNeue"
        style.text.outline.width = 5
        style.redaction.shape = .ellipse
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == style)
    }

    @Test("変化なしで終わった連続変更は、やり直しの履歴も壊さない")
    func 変化なしならやり直しが残る() {
        let doc = AnnotationDocument()
        doc.add(make(.rect))
        doc.undo()
        #expect(doc.canRedo)

        // クリックしただけ（何も変えない）。
        doc.beginChange()
        doc.commitChange()
        #expect(doc.canRedo)
        #expect(!doc.canUndo)
    }

    @Test("変化があれば、やり直しの履歴は確定時に破棄される")
    func 変化があればやり直しは消える() {
        let doc = AnnotationDocument()
        let a = make(.rect)
        doc.add(a)
        doc.undo()
        #expect(doc.canRedo)

        doc.add(make(.rect, at: 100))
        #expect(!doc.canRedo)

        // ドラッグ（実際に動かす）でも同様。
        doc.undo()
        doc.redo()
        doc.beginChange()
        var moved = doc.annotations[0]
        moved = AnnotationGeometry.moved(moved, by: CGSize(width: 5, height: 5))
        doc.setWithoutHistory(moved)
        doc.commitChange()
        #expect(!doc.canRedo)
        #expect(doc.canUndo)
    }

    @Test("mutate が結果的に変化なしのとき、やり直しが残る")
    func mutate変化なし() {
        let doc = AnnotationDocument()
        let a = make(.rect)
        doc.add(a)
        doc.add(make(.rect, at: 100), select: false)
        doc.undo()
        #expect(doc.canRedo)
        doc.select([a.id])
        doc.mutate { _ in }  // 何も変えない
        #expect(doc.canRedo)
        #expect(doc.undoStack.count == 1)
    }
}
