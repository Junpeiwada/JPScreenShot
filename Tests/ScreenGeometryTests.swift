import AppKit
import Testing

@testable import JPScreenShot

// 座標変換はマルチディスプレイで最も壊れやすい箇所（実装計画 6.1）。
// 純粋な計算部分を固定しておく。
@MainActor
@Suite("座標系の変換")
struct ScreenGeometryTests {

    @Test("AppKit → CoreGraphics の往復で元に戻る")
    func 往復変換() {
        let cases = [
            CGRect(x: 0, y: 0, width: 100, height: 50),
            CGRect(x: 100, y: 200, width: 300, height: 150),
            // 副画面が主画面より左や上にある配置では負の座標になる。
            CGRect(x: -500, y: 100, width: 200, height: 100),
        ]
        for rect in cases {
            let once = ScreenGeometry.convertToCoreGraphics(rect)
            let twice = ScreenGeometry.convertToCoreGraphics(once)
            #expect(abs(twice.origin.y - rect.origin.y) < 0.001)
            #expect(twice.origin.x == rect.origin.x)
            #expect(twice.size == rect.size)
        }
    }

    @Test("主画面の上端は CoreGraphics で y = 0 になる")
    func 主画面上端() {
        let height = ScreenGeometry.primaryScreenHeight
        // 上端に接する矩形
        let top = CGRect(x: 0, y: height - 100, width: 200, height: 100)
        #expect(ScreenGeometry.convertToCoreGraphics(top).origin.y == 0)
    }

    @Test("画面外の矩形はどのスクリーンにも属さない")
    func 画面外() {
        let outside = CGRect(x: 99_999, y: 99_999, width: 10, height: 10)
        #expect(ScreenGeometry.screen(containing: outside) == nil)
    }

    @Test("主画面上の矩形は主画面に解決される")
    func 主画面上の矩形() throws {
        let primary = try #require(NSScreen.screens.first)
        // 主画面の中央付近
        let rect = CGRect(
            x: primary.frame.midX - 50,
            y: primary.frame.midY - 50,
            width: 100,
            height: 100
        )
        #expect(ScreenGeometry.screen(containing: rect) === primary)
    }

    @Test("ディスプレイ ID が取得できる")
    func ディスプレイID() throws {
        let primary = try #require(NSScreen.screens.first)
        #expect(ScreenGeometry.displayID(of: primary) != nil)
    }
}
