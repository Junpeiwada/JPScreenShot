import AppKit
import Testing

@testable import JPScreenShot

// 重なりを差し引いた可視領域の計算（CAP-06）。
//
// 「ユーザーに見えているものだけを対象にする」の土台になる計算で、
// ハイライトの形も撮れるかどうかの判定もここから出る。走査線で帯に
// 切っているため境界の扱いを間違えやすく、画面がないと確かめられない
// 部分でもないので、純粋関数として固定しておく。
@MainActor
@Suite("ウィンドウの可視領域")
struct WindowPickerTests {

    /// 矩形群の合計面積。返る矩形どうしは重ならない前提で単純に足す。
    private func area(_ rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    private let target = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test("覆うものがなければウィンドウ全体が見えている")
    func 遮蔽なし() {
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [])
        #expect(visible == [target])
    }

    @Test("完全に覆われていれば可視領域はない")
    func 完全に遮蔽() {
        // 対象より大きい矩形で覆う。はみ出した分を引きすぎないことも見る。
        let occluder = CGRect(x: -50, y: -50, width: 300, height: 300)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        #expect(visible.isEmpty)
    }

    @Test("右半分が覆われれば左半分だけが残る")
    func 右半分を遮蔽() {
        let occluder = CGRect(x: 50, y: 0, width: 50, height: 100)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        #expect(visible == [CGRect(x: 0, y: 0, width: 50, height: 100)])
    }

    @Test("重ならない位置の矩形は可視領域に影響しない")
    func 交差しない遮蔽() {
        let occluder = CGRect(x: 200, y: 200, width: 50, height: 50)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        #expect(visible == [target])
    }

    @Test("中央をくり抜かれるとドーナツ状に残る")
    func 中央を遮蔽() {
        let occluder = CGRect(x: 25, y: 25, width: 50, height: 50)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        // 10000 - 2500。帯に分かれるので矩形の数は問わず面積で見る。
        #expect(area(visible) == 7500)
        // くり抜かれた中心は含まれない。
        #expect(!visible.contains { $0.contains(CGPoint(x: 50, y: 50)) })
        // 四隅は残っている。
        #expect(visible.contains { $0.contains(CGPoint(x: 5, y: 5)) })
        #expect(visible.contains { $0.contains(CGPoint(x: 95, y: 95)) })
    }

    @Test("覆う矩形どうしが重なっていても二重に引かない")
    func 遮蔽どうしの重なり() {
        // 0...60 と 40...100 で 40...60 が二重になる。単純な面積の
        // 足し算だと 6000 + 6000 = 12000 を引いてしまい、可視面積が負になる。
        let occluders = [
            CGRect(x: 0, y: 0, width: 60, height: 100),
            CGRect(x: 40, y: 0, width: 60, height: 100),
        ]
        let visible = WindowPicker.visibleRects(of: target, occludedBy: occluders)
        #expect(visible.isEmpty)
    }

    @Test("横に並んだ帯は 1 つの矩形にまとまる")
    func 横方向の結合() {
        // 下辺 20 を 2 つの矩形が分担して覆う。走査線は x = 50 で帯を
        // 切るが、残る領域の上下が揃っているので 1 枚に戻るはず。
        let occluders = [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 50, y: 0, width: 50, height: 20),
        ]
        let visible = WindowPicker.visibleRects(of: target, occludedBy: occluders)
        #expect(visible == [CGRect(x: 0, y: 20, width: 100, height: 80)])
    }

    @Test("L 字に残る形も面積が合う")
    func L字の可視領域() {
        // 右下の 1/4 を覆う。
        let occluder = CGRect(x: 50, y: 0, width: 50, height: 50)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        #expect(area(visible) == 7500)
        #expect(visible.contains { $0.contains(CGPoint(x: 25, y: 25)) })
        #expect(visible.contains { $0.contains(CGPoint(x: 75, y: 75)) })
        #expect(!visible.contains { $0.contains(CGPoint(x: 75, y: 25)) })
    }

    @Test("面積のないウィンドウは可視領域を持たない")
    func 潰れた矩形() {
        let flat = CGRect(x: 0, y: 0, width: 100, height: 0)
        #expect(WindowPicker.visibleRects(of: flat, occludedBy: []).isEmpty)
    }

    @Test("上下が揃っていない矩形はつながない")
    func 結合されない条件() {
        // 左は下 20 を、右は下 40 を覆う。残る帯は高さが違うので、
        // 横に隣接していても 1 枚にしてはいけない。まとめてしまうと
        // ハイライトが覆われている場所まで広がる。
        let occluders = [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 50, y: 0, width: 50, height: 40),
        ]
        let visible = WindowPicker.visibleRects(of: target, occludedBy: occluders)
        #expect(visible.count == 2)
        // 覆われるのは 50×20 と 50×40 の計 3000。
        #expect(area(visible) == 7000)
        // 右下（覆われている側）に食い込んでいないこと。
        #expect(!visible.contains { $0.contains(CGPoint(x: 75, y: 30)) })
    }

    @Test("辺で接するだけの矩形は覆っていない")
    func 辺で接する遮蔽() {
        // 対象の右辺にぴったり接する。交差の面積は 0 なので影響しない。
        let occluder = CGRect(x: 100, y: 0, width: 50, height: 100)
        let visible = WindowPicker.visibleRects(of: target, occludedBy: [occluder])
        #expect(visible == [target])
    }

    @Test("小数を含む座標でも帯が正しくつながる")
    func 非整数座標() {
        // スケーリング解像度ではウィンドウ矩形に小数が入る。帯の結合は
        // 幅を足し込んだ maxX と元の X を比べるため、厳密比較だと誤差で
        // 外れうる。面積と枚数の両方で見る。
        let target = CGRect(x: 0.5, y: 0.25, width: 100.5, height: 80.75)
        let occluders = [
            CGRect(x: 0.5, y: 0.25, width: 33.5, height: 10.5),
            CGRect(x: 34.0, y: 0.25, width: 33.5, height: 10.5),
            CGRect(x: 67.5, y: 0.25, width: 33.5, height: 10.5),
        ]
        let visible = WindowPicker.visibleRects(of: target, occludedBy: occluders)
        #expect(visible.count == 1)
        #expect(abs(area(visible) - 100.5 * (80.75 - 10.5)) < 0.001)
    }

    @Test("可視面積が 2% 以下なら対象にしない")
    func 可視判定の閾値() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 端が少しのぞいているだけのウィンドウは選ばせない。
        #expect(!WindowPicker.isEffectivelyVisible(visibleArea: 200, of: frame))
        #expect(WindowPicker.isEffectivelyVisible(visibleArea: 201, of: frame))
        #expect(!WindowPicker.isEffectivelyVisible(visibleArea: 0, of: frame))
        // 面積のないウィンドウは 0 除算にせず「見えていない」に倒す。
        #expect(!WindowPicker.isEffectivelyVisible(visibleArea: 100, of: .zero))
    }

    @Test("ハイライトの表示名はアプリ名とタイトルを組み合わせる")
    func 表示名の組み立て() {
        #expect(
            WindowPicker.label(applicationName: "Finder", windowTitle: "書類") == "Finder — 書類"
        )
        // タイトルが無い、またはアプリ名と同じなら重ねない。
        #expect(WindowPicker.label(applicationName: "Finder", windowTitle: "") == "Finder")
        #expect(WindowPicker.label(applicationName: "Xcode", windowTitle: "Xcode") == "Xcode")
        #expect(WindowPicker.label(applicationName: "Finder", windowTitle: "   ") == "Finder")
        // アプリ名が取れない場合はタイトルだけで示す。
        #expect(WindowPicker.label(applicationName: "", windowTitle: "無題") == "無題")
        #expect(WindowPicker.label(applicationName: "", windowTitle: "").isEmpty)
    }
}
