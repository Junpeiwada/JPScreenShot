import CoreGraphics
import Testing

@testable import JPScreenShot

// 書き出し（注釈の焼き込み）の確認。画面権限は要らない（メモリ上のビットマップだけ）。
@MainActor
@Suite("注釈の書き出し")
struct AnnotationRendererTests {

    /// 画素ごとに値が違う不透明な画像（ぼかし・モザイクで変化が出るように）。
    private func makeBase(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * context.bytesPerRow + x * 4
                data[i] = UInt8((x * 255) / max(width - 1, 1))
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = UInt8((x * 37 + y * 91) % 256)
                data[i + 3] = 255
            }
        }
        return context.makeImage()!
    }

    /// 単色の不透明画像。
    private func makeSolid(width: Int, height: Int, white: Bool = true) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(white ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 画素を RGBA の配列で取り出す（左上原点・行優先）。
    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        return Array(buffer)
    }

    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    @Test("注釈 0 件の書き出しは元画像と同じ寸法・同じ画素")
    func 注釈なし() throws {
        let base = makeBase(width: 64, height: 48)
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 2, annotations: []))
        #expect(output.width == 64 && output.height == 48)
        #expect(pixels(output) == pixels(base))
    }

    @Test("画像の外にだけある注釈では画素が変わらない（経路を通っても元と一致）")
    func 範囲外の注釈() throws {
        let base = makeBase(width: 64, height: 48)
        let far = Annotation(kind: .rect, start: CGPoint(x: 500, y: 500), end: CGPoint(x: 600, y: 600))
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [far]))
        #expect(output.width == 64 && output.height == 48)
        #expect(pixels(output) == pixels(base))
    }

    @Test("モザイクは範囲内の画素だけが変わる")
    func モザイク() throws {
        let width = 80, height = 60
        let base = makeBase(width: width, height: height)
        var mosaic = Annotation(kind: .mosaic, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 50))
        mosaic.style.redaction.strength = 10
        let output = try #require(
            AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [mosaic]))
        #expect(output.width == width && output.height == height)

        let before = pixels(base)
        let after = pixels(output)
        var changedInside = 0
        for y in 0..<height {
            for x in 0..<width {
                let inside = (20..<60).contains(x) && (10..<50).contains(y)
                let same = pixel(before, width: width, x: x, y: y) == pixel(after, width: width, x: x, y: y)
                if inside {
                    if !same { changedInside += 1 }
                } else {
                    #expect(same, "範囲外の画素が変わった (\(x), \(y))")
                }
            }
        }
        #expect(changedInside > 0)
    }

    @Test("ぼかしも範囲内だけが変わり、キャッシュが効く")
    func ぼかしとキャッシュ() throws {
        let base = makeBase(width: 80, height: 60)
        var blur = Annotation(kind: .blur, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 50))
        blur.style.redaction.strength = 6
        let renderer = RedactionRenderer(base: base, scale: 1)
        let first = try #require(renderer.piece(for: blur))
        #expect(renderer.cachedCount == 1)
        _ = renderer.piece(for: blur)
        #expect(renderer.cachedCount == 1)  // 同じ範囲・強さ・形は再計算しない
        #expect(first.rect == CGRect(x: 20, y: 10, width: 40, height: 40))

        // 強さを変えても、注釈 ID ごとに最新の 1 件だけ（ドラッグ中に増え続けない）。
        blur.style.redaction.strength = 9
        _ = renderer.piece(for: blur)
        #expect(renderer.cachedCount == 1)
        for x in stride(from: 20.0, to: 40.0, by: 1.0) {
            blur.start.x = x
            _ = renderer.piece(for: blur)
        }
        #expect(renderer.cachedCount == 1)

        // 別の注釈は別枠。無くなった注釈は prune で解放される。
        var other = Annotation(kind: .mosaic, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 30, y: 30))
        other.style.redaction.strength = 10
        _ = renderer.piece(for: other)
        #expect(renderer.cachedCount == 2)
        renderer.prune(keeping: [other.id])
        #expect(renderer.cachedCount == 1)

        renderer.removeAllCachedImages()
        #expect(renderer.cachedCount == 0)
    }

    /// グレースケール（RGB ではない色空間）の画像。
    private func makeGray(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                data[y * context.bytesPerRow + x] = UInt8((x * 7 + y * 13) % 256)
            }
        }
        return context.makeImage()!
    }

    @Test("グレースケール画像でも、ぼかし・モザイクの範囲が元のまま素通しにならない")
    func グレースケールでも加工される() throws {
        for kind in [AnnotationKind.blur, .mosaic] {
            let base = makeGray(width: 80, height: 60)
            var annotation = Annotation(kind: kind, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 50))
            annotation.style.redaction.strength = 10
            let output = try #require(
                AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [annotation]))
            let before = pixels(base)
            let after = pixels(output)
            var changed = 0
            var total = 0
            for y in 10..<50 {
                for x in 20..<60 {
                    total += 1
                    if pixel(before, width: 80, x: x, y: y) != pixel(after, width: 80, x: x, y: y) {
                        changed += 1
                    }
                }
            }
            // 範囲の大半は元と違う画素になっている（素通しなら 0）。
            #expect(changed > total / 2, "\(kind) の範囲が加工されていない")
            // 範囲外は不変。
            #expect(pixel(before, width: 80, x: 5, y: 5) == pixel(after, width: 80, x: 5, y: 5))
        }
    }

    @Test("加工を直接頼んでも、グレースケール画像の範囲が元のまま返らない")
    func 加工画像は素通しにならない() throws {
        let base = makeGray(width: 64, height: 64)
        let renderer = RedactionRenderer(base: base, scale: 1)
        let piece = try #require(
            renderer.piece(
                rect: CGRect(x: 8, y: 8, width: 40, height: 40), isMosaic: false, strength: 8,
                shape: .ellipse))
        #expect(piece.image.width == 40 && piece.image.height == 40)
        // 楕円の中心は不透明（隠れている）。
        let data = pixels(piece.image)
        let center = (20 * 40 + 20) * 4
        #expect(data[center + 3] == 255)
    }

    @Test("上下非対称な範囲のぼかし・モザイクは、範囲外が変わらず上下逆にも貼られない")
    func 上下非対称な範囲() throws {
        let width = 90, height = 120
        let base = makeBase(width: width, height: height)
        for kind in [AnnotationKind.blur, .mosaic] {
            // 画像の上寄りに縦長の範囲（下側には何もない）。
            var annotation = Annotation(kind: kind, start: CGPoint(x: 30, y: 8), end: CGPoint(x: 60, y: 48))
            annotation.style.redaction.strength = 8
            let output = try #require(
                AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [annotation]))
            let before = pixels(base)
            let after = pixels(output)
            for y in 0..<height {
                for x in 0..<width {
                    let inside = (30..<60).contains(x) && (8..<48).contains(y)
                    if !inside {
                        #expect(
                            pixel(before, width: width, x: x, y: y) == pixel(after, width: width, x: x, y: y),
                            "\(kind) 範囲外 (\(x), \(y)) が変わった")
                    }
                }
            }
            // 範囲内の画素は、元画像のその範囲の近傍の色に近い（上下逆なら、
            // 画像の縦方向のグラデーション（G 成分が y に比例）が反転して大きくずれる）。
            // 範囲の上端付近・下端付近の G 成分は、元の G（y に比例）と近い。
            let topInside = pixel(after, width: width, x: 45, y: 12).g
            let bottomInside = pixel(after, width: width, x: 45, y: 44).g
            let topExpected = pixel(before, width: width, x: 45, y: 12).g
            let bottomExpected = pixel(before, width: width, x: 45, y: 44).g
            #expect(abs(topInside - topExpected) < 40, "\(kind) 上端が上下逆の疑い")
            #expect(abs(bottomInside - bottomExpected) < 40, "\(kind) 下端が上下逆の疑い")
            #expect(bottomInside > topInside)  // 元のグラデーションの向きが保たれる
        }
    }

    @Test("書き出しは補間なし・画面は補間ありでも、同じ範囲を加工する（描画の入口が通る）")
    func 画面用の描画経路() throws {
        let base = makeBase(width: 80, height: 60)
        var blur = Annotation(kind: .blur, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 40))
        blur.style.redaction.strength = 6
        let renderer = RedactionRenderer(base: base, scale: 1)
        let context = CGContext(
            data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 60)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw([blur], using: renderer, in: context, exporting: false)
        #expect(context.makeImage() != nil)
        #expect(renderer.cachedCount == 1)
    }

    @Test("楕円形のぼかしは外接矩形の角が元のまま残る")
    func 楕円ぼかし() throws {
        let width = 80, height = 80
        let base = makeBase(width: width, height: height)
        var blur = Annotation(kind: .blur, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 70))
        blur.style.redaction.strength = 8
        blur.style.redaction.shape = .ellipse
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [blur]))
        let before = pixels(base)
        let after = pixels(output)
        // 角（楕円の外）は不変、中心は変化。
        #expect(pixel(before, width: width, x: 11, y: 11) == pixel(after, width: width, x: 11, y: 11))
        #expect(pixel(before, width: width, x: 40, y: 40) != pixel(after, width: width, x: 40, y: 40))
    }

    @Test("矩形を描くと該当画素が色付き、内側と外側は変わらない（2x）")
    func 矩形() throws {
        // 100×100 ポイント = 200×200 ピクセル。
        let base = makeSolid(width: 200, height: 200)
        var rect = Annotation(kind: .rect, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80))
        rect.style.color = RGBAColor(red: 1, green: 0, blue: 0)
        rect.style.lineWidth = 4  // 8 ピクセル幅
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 2, annotations: [rect]))
        #expect(output.width == 200 && output.height == 200)

        let data = pixels(output)
        // 上辺の枠線（y = 40 ピクセル付近、x は中央）が赤。
        let edge = pixel(data, width: 200, x: 100, y: 40)
        #expect(edge.r > 240 && edge.g < 15 && edge.b < 15)
        // 左辺の枠線も赤。
        let left = pixel(data, width: 200, x: 40, y: 100)
        #expect(left.r > 240 && left.g < 15)
        // 内側（塗りなし）と外側は白のまま。
        #expect(pixel(data, width: 200, x: 100, y: 100) == (255, 255, 255))
        #expect(pixel(data, width: 200, x: 5, y: 5) == (255, 255, 255))
    }

    @Test("塗りありの矩形は内部も色付く")
    func 塗り() throws {
        let base = makeSolid(width: 100, height: 100)
        var rect = Annotation(kind: .rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90))
        rect.style.color = RGBAColor(red: 0, green: 0, blue: 1)
        rect.style.fill = .solid
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [rect]))
        let center = pixel(pixels(output), width: 100, x: 50, y: 50)
        #expect(center.b > 240 && center.r < 15)
    }

    @Test("矢印は終点側に頭が付く")
    func 矢印() throws {
        let base = makeSolid(width: 200, height: 100)
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50))
        arrow.style.color = RGBAColor(red: 0, green: 0, blue: 0)
        arrow.style.lineWidth = 4
        arrow.style.arrowHeads = .end
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [arrow]))
        let data = pixels(output)
        // 頭の底辺付近（終点から 15pt 手前）は、軸（半幅 2）より上下に広がっている。
        #expect(pixel(data, width: 200, x: 165, y: 50 - 4).r < 100)
        // 始点側は軸だけなので同じ高さは白。
        #expect(pixel(data, width: 200, x: 30, y: 50 - 4) == (255, 255, 255))
    }

    @Test("影は下方向に落ちる（Retina でもポイント値どおり）")
    func 影の向き() throws {
        // 200×200 ピクセル = 100×100 ポイント（2x）。
        let base = makeSolid(width: 200, height: 200)
        var rect = Annotation(kind: .rect, start: CGPoint(x: 30, y: 30), end: CGPoint(x: 70, y: 70))
        rect.style.color = RGBAColor(red: 1, green: 0, blue: 0)
        rect.style.fill = .solid
        rect.style.lineWidth = 0
        rect.style.shadow = ShadowStyle(isOn: true, blur: 0, distance: 5)  // 10 ピクセル下へ
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 2, annotations: [rect]))
        let data = pixels(output)
        // 矩形の下端（y = 140 ピクセル）のすぐ下は影で暗い。上端のすぐ上は白のまま。
        #expect(pixel(data, width: 200, x: 100, y: 145).g < 200)
        #expect(pixel(data, width: 200, x: 100, y: 55) == (255, 255, 255))
        // ずれ（10 ピクセル）より遠くは白。
        #expect(pixel(data, width: 200, x: 100, y: 155) == (255, 255, 255))
    }

    @Test("テキストは外接矩形の中に描かれ、縁取りは文字色と別の色で出る")
    func テキスト() throws {
        let base = makeSolid(width: 240, height: 120)
        var text = Annotation(kind: .text, start: CGPoint(x: 20, y: 20), end: .zero, text: "MMMM")
        text.style.text.size = 48
        text.style.text.color = RGBAColor(red: 1, green: 1, blue: 1)
        text.style.text.outline = OutlineStyle(isOn: true, color: RGBAColor(red: 0, green: 0, blue: 0), width: 3)
        let bounds = AnnotationGeometry.bounds(of: text)
        let output = try #require(AnnotationRenderer.renderFlattened(base: base, scale: 1, annotations: [text]))
        let after = pixels(output)

        // 外接矩形の中に黒（縁）が出ている。
        var darkInside = 0
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) where pixel(after, width: 240, x: x, y: y).r < 60 {
                darkInside += 1
            }
        }
        #expect(darkInside > 0)
        // 外接矩形（縁の張り出し分の余白を除く）の遠くは白のまま。
        #expect(pixel(after, width: 240, x: 235, y: 115) == (255, 255, 255))
    }
}
