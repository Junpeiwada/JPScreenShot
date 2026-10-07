import CoreGraphics
import Testing

@testable import JPScreenShot

/// 結果ウィンドウの初期サイズの実測補正（不足分の計算）。
@MainActor
@Suite("結果ウィンドウの初期サイズ補正")
struct ResultWindowFitTests {

    private let margin: CGFloat = 16
    private let roomy = CGSize(width: 1000, height: 1000)

    @Test("不足が無ければ広げない")
    func 不足なし() {
        let extra = ResultWindow.extraSize(
            viewport: CGSize(width: 400, height: 300), pointSize: CGSize(width: 300, height: 200),
            margin: margin, available: roomy)
        #expect(extra == .zero)
    }

    @Test("数 pt 足りなければその分だけ広げる")
    func 不足あり() {
        // 必要: 300+32=332 × 200+32=232。実測 330 × 228。
        let extra = ResultWindow.extraSize(
            viewport: CGSize(width: 330, height: 228), pointSize: CGSize(width: 300, height: 200),
            margin: margin, available: roomy)
        #expect(extra == CGSize(width: 2, height: 4))
    }

    @Test("端数のポイント寸法は切り上げて比べる")
    func 端数() {
        // 200.5 → 201。必要 233。実測 232.5 なら 0.5 足りない。
        let extra = ResultWindow.extraSize(
            viewport: CGSize(width: 1000, height: 232.5),
            pointSize: CGSize(width: 100, height: 200.5), margin: margin, available: roomy)
        #expect(extra == CGSize(width: 0, height: 0.5))
    }

    @Test("画面に収まらない分は広げない（スクロールで見る）")
    func 画面上限() {
        let extra = ResultWindow.extraSize(
            viewport: CGSize(width: 400, height: 300), pointSize: CGSize(width: 5000, height: 200),
            margin: margin, available: CGSize(width: 100, height: -5))
        #expect(extra == CGSize(width: 100, height: 0))
    }
}
