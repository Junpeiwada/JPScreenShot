import AppKit
import Testing

@testable import JPScreenShot

// 新規キャプチャの赤ボタン。標準の borderedProminent はウィンドウが非アクティブになると
// グレーになって白文字が見えなくなったため、色を自前で決めている。
@MainActor
@Suite("赤ボタンの色")
struct FilledRedButtonStyleTests {

    private func saturation(_ color: NSColor) -> CGFloat {
        color.usingColorSpace(.sRGB)!.saturationComponent
    }

    @Test("非アクティブでは彩度を少し落とすが、グレーにはしない")
    func 非アクティブ() {
        let active = FilledRedButtonStyle.fillColor(isActive: true, isPressed: false)
        let inactive = FilledRedButtonStyle.fillColor(isActive: false, isPressed: false)
        #expect(saturation(inactive) < saturation(active))
        // 赤だと分かる彩度は残す。
        #expect(saturation(inactive) > 0.4)
    }

    @Test("押している間は暗くなる")
    func 押下() {
        let normal = FilledRedButtonStyle.fillColor(isActive: true, isPressed: false)
        let pressed = FilledRedButtonStyle.fillColor(isActive: true, isPressed: true)
        #expect(
            pressed.usingColorSpace(.sRGB)!.brightnessComponent
                < normal.usingColorSpace(.sRGB)!.brightnessComponent)
    }
}
