// ColorGainMap.swift
// HDRForge（GainForgeCore）の ColorGainMap の移植。SDR ベースと HDR の差分から
// 「3ch カラーゲインマップ」を自前で作り、ISO ゲインマップとして HEIC に添付する。
// 明部の色温度調整（HighlightWarmth / HighlightTint）は持ち込んでいない。
//
// なぜ必要か:
//   CoreImage の `heif10Representation(of:options:[.hdrImage:])` が作るゲインマップは
//   1ch モノクロで、チャンネルごとの差が輝度に平均化されて消える。ISO ゲインマップ自体は
//   カラーを扱えるので、ImageIO の低レベル経路（`CGImageDestinationAddAuxiliaryDataInfo`）で
//   3ch(32BGRA) を自前添付する。
//
// metadata の扱い（最大の落とし穴）:
//   ゲインマップ metadata をゼロから自作すると `CGImageDestinationFinalize` が false になる。
//   CoreImage に小さなダミーを一度だけ書かせて正規の metadata を借り、`ChannelMetadata` を
//   配列タグごと差し替えて `GainMapMin/Max` を画像ごとの実測値にする。
//   カーネル（Metal）が読めないとダミーも作れず `template` が nil になる。

import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// SDR ベースと HDR 版の差分から 3ch カラーゲインマップを作る。
enum ColorGainMap {

    /// ゲイン上限（log2）の**上限クランプ**。4.0 = 16 倍。
    ///
    /// 実際に使う値は画像ごとに `measureMaxLog2` で実測する（下記）。これはその安全上限。
    /// XDR ディスプレイは輝度を絞ると SDR 白に対するヘッドルームが伸び、HDR 版は最大で 16 倍近くに
    /// なり得る。上限が低いとその明部がゲイン上限で頭打ちになる（3.25 = 約 9.5 倍では足りない）。
    /// 実測値がこれより小さければこの上限は使われないので、余裕を持たせて 16 倍にしている。
    static let maxLog2Ceiling: Double = 4.0

    /// ゲイン上限の下限クランプ。ゲインがほぼ無い画像で 0 除算・過大な量子化誤差を避ける。
    static let maxLog2Floor: Double = 0.25

    /// `measureMaxLog2` が使う内部スケール。`CIAreaMaximum` の出力が [0,1] にクランプされても
    /// 値を失わないよう、log2 ゲインをこの値で割ってから最大を取り、後で掛け戻す。
    private static let measureScale: Double = 8.0

    /// ISO ゲインマップの base/alternate オフセット。metadata の `BaseOffset` / `AlternateOffset` にも
    /// 同じ値を書くので、ゲイン計算式（`log2((alt+offset)/(base+offset))`）は復元側と一致する。
    ///
    /// ★1/64 にする（HDRForge の 1e-5 から変更・2026-10-07 実機で判明）。
    /// こちらのベースは 8bit の SDR 版で、暗い色成分が 0 に丸められる。1e-5 だと分母がほぼ 0 になり、
    /// HDR 側の 0.002 程度の値でも log2 比が 7 段を超えて `measureMaxLog2` が上限（4.0）に張り付いた
    /// （実測: 本来 2.26 段の画像で GainMapMax = 4.0）。上限を過大に宣言すると表示時のゲインが
    /// 丸ごと弱まる（`measureMaxLog2` の説明）。1/64 は ISO ゲインマップで一般的な値
    /// （libultrahdr の既定値も 1/64）で、ガンマ符号化された 8bit の暗部はリニアで 0〜数×10⁻³ の
    /// 誤差を持つが、それを吸収しつつ SDR 白付近の比はほぼ変えない。
    /// HDRForge はベースを HDR から連続値で作るので 1e-5 で困らなかった。
    static let offset: Double = 1.0 / 64.0

    // MARK: - metadata

    /// `template` のダミーを作るカーネル（暗部は等倍・明部だけ `m` 倍）。
    static let templateKernel: CIColorKernel? = MetalKernelLibrary.colorKernel("gainforgeTemplate")

    /// CoreImage に小さなダミーを書かせて、正規のゲインマップ metadata と ColorSpace を借りる。
    ///
    /// バッチで毎回書き出さないよう一度だけ評価する。ダミーは 32×32 のグレーグラデで、
    /// 暗部は等倍・明部だけ伸ばしてある。**得られた値そのものは使わず** `makeMetadata` で
    /// 画像ごとの実測値へ差し替えるので、ここでは「正規の器」が手に入ればよい。
    /// 保持するのは読み取り専用の借用元。使うときは必ず `CGImageMetadataCreateMutableCopy` して
    /// コピーを書き換えるため、共有インスタンスが変更されることはない（並列変換でも安全）。
    nonisolated(unsafe) static let template: (metadata: CGImageMetadata, colorSpace: CGColorSpace)? = {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let v = UInt8(Double(x) / Double(n - 1) * 255)
                let i = (y * n + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: n * 4, space: p3,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent),
              let kernel = templateKernel
        else { return nil }

        let sdr = CIImage(cgImage: cg)
        guard let hdr = kernel.apply(extent: sdr.extent, arguments: [sdr, Float(pow(2.0, maxLog2Ceiling))]) else {
            return nil
        }
        let ctx = CIContext(options: [.workingColorSpace: linear])
        guard let data = try? ctx.heif10Representation(of: sdr, colorSpace: p3, options: [.hdrImage: hdr]),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let meta = aux[kCGImageAuxiliaryDataInfoMetadata as String],
              let csValue = aux[kCGImageAuxiliaryDataInfoColorSpace as String],
              CFGetTypeID(csValue as CFTypeRef) == CGColorSpace.typeID
        else { return nil }
        return (meta as! CGImageMetadata, csValue as! CGColorSpace)
    }()

    /// 借用 metadata の `ChannelMetadata` を差し替え、ゲイン範囲を `0…maxLog2` に設定した metadata を作る。
    ///
    /// `ChannelMetadata` は1要素のままでよい（3ch データを添付しても全チャンネル共通のパラメータとして
    /// 解釈され、色は保持される。実測確認済み）。`AlternateHeadroom` も同じ値へ合わせる。
    static func makeMetadata(maxLog2: Double) -> CGImageMetadata? {
        guard let base = template?.metadata,
              let md = CGImageMetadataCreateMutableCopy(base) else { return nil }

        let ns = "http://ns.apple.com/HDRToneMap/1.0/" as CFString
        let prefix = "HDRToneMap" as CFString
        func tag(_ name: String, _ type: CGImageMetadataType, _ value: Any) -> CGImageMetadataTag? {
            CGImageMetadataTagCreate(ns, prefix, name as CFString, type, value as CFTypeRef)
        }
        guard let minTag = tag("GainMapMin", .default, "0.000000"),
              let maxTag = tag("GainMapMax", .default, String(format: "%f", maxLog2)),
              let gammaTag = tag("Gamma", .default, "1.000000"),
              let baseOffsetTag = tag("BaseOffset", .default, String(format: "%f", offset)),
              let altOffsetTag = tag("AlternateOffset", .default, String(format: "%f", offset)),
              let channel = tag("[0]", .structure, [
                  "GainMapMin": minTag,
                  "GainMapMax": maxTag,
                  "Gamma": gammaTag,
                  "BaseOffset": baseOffsetTag,
                  "AlternateOffset": altOffsetTag,
              ] as [String: Any]),
              let array = tag("ChannelMetadata", .arrayOrdered, [channel] as CFArray),
              CGImageMetadataSetTagWithPath(md, nil, "HDRToneMap:ChannelMetadata" as CFString, array)
        else { return nil }

        // ゲインマップを完全適用したときのヘッドルーム。ゲイン上限に合わせておく。
        // ★ここに入れる maxLog2 は offset 込みのゲイン最大値 log2((alt+offset)/(base+offset)) の実測で、
        // 真の log2(H)（offset 抜きの比）より 1% 未満小さい。厳密には微小にずれるが、表示時の重み
        // log2(表示ヘッドルーム)/AlternateHeadroom が 1% 未満強まるだけなので、意図した近似として許容する。
        guard CGImageMetadataSetValueWithPath(md, nil, "HDRToneMap:AlternateHeadroom" as CFString,
                                              String(format: "%f", maxLog2) as CFString) else {
            return nil
        }
        return md
    }

    // MARK: - ゲインマップ本体

    /// log2 ゲインを `measureScale` で割って [0,1] に収めるカーネル（最大値の実測用）。
    /// `CIAreaMaximum` は出力を [0,1] にクランプし得るため、スケールしてから最大を取る。
    static let logGainKernel: CIColorKernel? = MetalKernelLibrary.colorKernel("gainforgeLogGain")

    /// この画像で実際に必要なゲイン上限（log2）を測る。
    ///
    /// **これを固定値にしてはいけない**。ISO ゲインマップの適用重みは
    /// `w = log2(表示ヘッドルーム) / AlternateHeadroom` で決まるため、実際の最大ゲインより
    /// 大きな上限を宣言すると、その比の分だけ**表示時のゲインが丸ごと弱まる**
    /// （実測: 上限 3.25 固定にしたところ、本来 1.10 で足りる画像で効果が約 1/3 に薄まった）。
    /// CoreImage の自動生成も画像ごとに実測した値を入れている。
    static func measureMaxLog2(base: CIImage, hdr: CIImage, context: CIContext) -> Double {
        guard let kernel = logGainKernel,
              let logGain = kernel.apply(extent: base.extent,
                                         arguments: [base, hdr, Float(offset), Float(1.0 / measureScale)]),
              let maxFilter = CIFilter(name: "CIAreaMaximum", parameters: [
                  kCIInputImageKey: logGain,
                  kCIInputExtentKey: CIVector(cgRect: base.extent),
              ]),
              let reduced = maxFilter.outputImage
        else { return maxLog2Ceiling }

        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            context.render(reduced, toBitmap: p, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        let peak = Double(max(px[0], max(px[1], px[2]))) * measureScale
        guard peak.isFinite else { return maxLog2Ceiling }
        return min(max(peak, maxLog2Floor), maxLog2Ceiling)
    }

    /// ベースと HDR の比を正規化ゲインへ変換するカーネル。
    /// 作業空間（拡張リニア Display P3）で走らせ、出力は色変換せずそのまま量子化する。
    static let gainMapKernel: CIColorKernel? = MetalKernelLibrary.colorKernel("gainforgeGainMap")

    /// SDR ベースと合成 HDR から、HEIC に添付する ISO ゲインマップ補助辞書を組み立てる。
    ///
    /// - Parameters:
    ///   - base: SDR ベース（作業空間のリニア値としてカーネルに入る）。
    ///   - hdr: 合成した拡張レンジ HDR。`base` と同じ extent であること。
    ///   - context: 作業空間が拡張リニア Display P3 の `CIContext`。
    /// - Returns: `CGImageDestinationAddAuxiliaryDataInfo` にそのまま渡せる辞書。
    static func auxiliaryInfo(base: CIImage, hdr: CIImage, context: CIContext) throws -> [String: Any] {
        let extent = base.extent
        let w = Int(extent.width.rounded())
        let h = Int(extent.height.rounded())
        guard w > 0, h > 0 else { throw ExportError.sizeMismatch }

        // ゲイン上限はこの画像の実測値を使う（固定値だと表示時のゲインが丸ごと弱まる）。
        let peakLog2 = measureMaxLog2(base: base, hdr: hdr, context: context)

        guard let kernel = gainMapKernel, template != nil else { throw ExportError.kernelUnavailable }
        guard let gainCI = kernel.apply(extent: extent,
                                        arguments: [base, hdr, Float(1.0 / peakLog2), Float(offset)]),
              let metadata = makeMetadata(maxLog2: peakLog2),
              let colorSpace = template?.colorSpace
        else { throw ExportError.colorGainMapFailed }

        // BGRA8 は 1 画素 4 バイトなので rowBytes は常に 4 の倍数（パディング不要）。
        // colorSpace に nil を渡し、作業空間で計算した正規化ゲインを色変換せずそのまま量子化する。
        let bytesPerRow = w * 4
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            context.render(gainCI, toBitmap: ptr, rowBytes: bytesPerRow,
                           bounds: extent, format: .BGRA8, colorSpace: nil)
        }

        return [
            kCGImageAuxiliaryDataInfoData as String: data as CFData,
            kCGImageAuxiliaryDataInfoDataDescription as String: [
                "PixelFormat": Int(kCVPixelFormatType_32BGRA),
                "BytesPerRow": bytesPerRow,
                "Width": w,
                "Height": h,
            ],
            kCGImageAuxiliaryDataInfoMetadata as String: metadata,
            kCGImageAuxiliaryDataInfoColorSpace as String: colorSpace,
        ]
    }

    /// 書き出した HEIC のゲインマップがカラー（モノクロでない）であることを検算する。
    ///
    /// 添付は成功しても保存段で 1ch へ落とされていないかを確認する（落とし穴6 と同趣旨）。
    /// ImageIO は 3ch を 4:2:0 YCbCr（`'420f'` 等）へ変換して保存するため、
    /// 輝度のみの `'L008'` でないことをもって判定する。
    static func isColorGainMap(data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return isColorGainMap(src)
    }

    private static func isColorGainMap(_ src: CGImageSource) -> Bool {
        guard let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let format = desc["PixelFormat"] as? Int
        else { return false }
        // 'L008'（8bit Luminance）= モノクロ。それ以外（4:2:0 等）はクロマを持つ。
        let monochrome = Int(0x4C303038)
        return format != monochrome
    }
}
