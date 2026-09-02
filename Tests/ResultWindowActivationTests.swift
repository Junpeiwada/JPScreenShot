import AppKit
import Testing

@testable import JPScreenShot

// メニューバーアイコンのクリックを「キャプチャ開始」と「結果ウィンドウの
// 前面化」のどちらに振り分けるかの判定（CAP-08）。
// 誤ると「何度クリックしてもキャプチャが始まらない」詰み方をするので固定する。
@MainActor
@Suite("結果ウィンドウの前面化判定")
struct ResultWindowActivationTests {

    @Test("他アプリが前面なら呼び戻す")
    func 他アプリが前面() {
        #expect(
            ResultWindow.shouldBringToFront(
                isVisible: true,
                isMiniaturized: false,
                isAppActive: false,
                isOnActiveSpace: true
            ))
    }

    @Test("自アプリがアクティブなら呼び戻さずキャプチャへ進む")
    func 自アプリがアクティブ() {
        // アクティブな間は .floating で手前にいるので見失っていない。
        // 環境設定ウィンドウがキーの場合もこちらに含まれる。
        #expect(
            !ResultWindow.shouldBringToFront(
                isVisible: true,
                isMiniaturized: false,
                isAppActive: true,
                isOnActiveSpace: true
            ))
    }

    @Test("最小化されていれば、アプリがアクティブでも呼び戻す")
    func 最小化() {
        // 最小化中は isVisible が false になる点に注意。
        for isAppActive in [true, false] {
            #expect(
                ResultWindow.shouldBringToFront(
                    isVisible: false,
                    isMiniaturized: true,
                    isAppActive: isAppActive,
                    isOnActiveSpace: true
                ))
        }
    }

    @Test("別 Space にあるときは呼び戻さない（Space 切り替えを避ける）")
    func 別Space() {
        #expect(
            !ResultWindow.shouldBringToFront(
                isVisible: true,
                isMiniaturized: false,
                isAppActive: false,
                isOnActiveSpace: false
            ))
    }

    @Test("⌘H で隠されているときは呼び戻さない")
    func 非表示() {
        #expect(
            !ResultWindow.shouldBringToFront(
                isVisible: false,
                isMiniaturized: false,
                isAppActive: false,
                isOnActiveSpace: true
            ))
    }
}
