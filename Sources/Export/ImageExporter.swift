import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// 結果画面の保存・コピーで使う書き出し器（実装計画-HDR P4-3）。
//
// 入力は「注釈を焼き込み済みの SDR 版／HDR 版」の CGImage、出力はファイルの中身（Data）。
// 画面にもファイルにも触らない（保存先・ファイル名・クリップボードは呼び出し側）。
//
//   SDR: HEIC（8bit）／PNG（8bit・従来どおり）／JPEG
//   HDR: HEIC（10bit ベース＋3ch ゲインマップ）／PNG（16bit・ITU-R 2100 PQ）／JPEG（1ch ゲインマップ）
//
// スレッド: 重い（4K 級の 10bit HEVC エンコードで数百 ms〜数秒）ので、メインから呼ぶときは
// `Task.detached` などで外へ出す。ここは状態を持たず、CGImage（Sendable）だけを受け取る。
//
// 失敗は `ExportError` で投げる。ゲインマップが作れないときに黙って SDR へ落とすことはしない
// （利用者は HDR で保存したつもりになるため）。
enum ImageExporter {

    /// 保存形式。
    enum Format: String, CaseIterable, Sendable {
        case heic
        case png
        case jpeg

        /// ファイル拡張子。
        var fileExtension: String {
            switch self {
            case .heic: "heic"
            case .png: "png"
            case .jpeg: "jpg"
            }
        }

        /// UI に出す名前。
        var label: String {
            switch self {
            case .heic: "HEIC"
            case .png: "PNG"
            case .jpeg: "JPG"
            }
        }

        var type: UTType {
            switch self {
            case .heic: .heic
            case .png: .png
            case .jpeg: .jpeg
            }
        }
    }

    /// HEIC・JPEG の非可逆圧縮の品質（0〜1）。スクリーンショットは文字の縁が命なので高めにする。
    static let lossyQuality: Double = 0.9

    /// 作業空間（ColorGainMap の前提どおり拡張リニア Display P3・float）。
    /// `CIContext` はスレッドセーフなので呼び出しごとに作る（共有のキャッシュを持たない）。
    private static func makeContext() throws -> (CIContext, CGColorSpace) {
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3)
        else { throw ExportError.imageConversionFailed }
        let context = CIContext(options: [
            .workingColorSpace: linear,
            .workingFormat: CIFormat.RGBAh.rawValue,
        ])
        return (context, p3)
    }

    /// 書き出す。
    /// - Parameters:
    ///   - sdr: 注釈込みの SDR 版。
    ///   - hdr: 注釈込みの HDR 版（拡張 sRGB・16bit float）。`dynamicRange == .hdr` のとき必須。
    static func export(
        format: Format, dynamicRange: ImageDynamicRange, sdr: CGImage, hdr: CGImage?
    ) throws -> Data {
        switch dynamicRange {
        case .sdr:
            return try exportSDR(format: format, image: sdr)
        case .hdr:
            guard let hdr else { throw ExportError.hdrImageMissing }
            guard hdr.width == sdr.width, hdr.height == sdr.height else {
                throw ExportError.sizeMismatch
            }
            return try exportHDR(format: format, sdr: sdr, hdr: hdr)
        }
    }

    // MARK: - SDR

    private static func exportSDR(format: Format, image: CGImage) throws -> Data {
        switch format {
        case .png:
            // 従来どおり（NSBitmapImageRep 経由）。見た目・バイト列を変えない。
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw ExportError.encodingFailed("PNG") }
            return data
        case .heic:
            return try encodeWithImageIO(image, type: .heic, quality: lossyQuality, name: "HEIC")
        case .jpeg:
            // JPEG にアルファは無い。透明部（ウィンドウ影の外側など）が黒く潰れないよう白へ敷く。
            let (context, _) = try makeContext()
            let space = HDRPixelFormat.sdrColorSpace(for: image)
            let flat = Self.onWhite(CIImage(cgImage: image))
            let options: [CIImageRepresentationOption: Any] = [Self.qualityKey: lossyQuality]
            guard let data = context.jpegRepresentation(of: flat, colorSpace: space, options: options)
            else { throw ExportError.encodingFailed("JPEG") }
            return data
        }
    }

    private static func encodeWithImageIO(
        _ image: CGImage, type: UTType, quality: Double, name: String
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed(name) }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed(name) }
        return data as Data
    }

    // MARK: - HDR

    private static func exportHDR(format: Format, sdr: CGImage, hdr: CGImage) throws -> Data {
        // 両版を CIImage にして作業空間（拡張リニア Display P3）へ揃える。SDR 版はディスプレイの
        // 色空間、HDR 版は拡張 sRGB のタグを持つので、色の値の差は CoreImage が吸収する。
        let (context, p3) = try makeContext()
        let base = CIImage(cgImage: sdr)
        let alt = CIImage(cgImage: hdr)

        switch format {
        case .png:
            guard let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
                  let data = context.pngRepresentation(of: alt, format: .RGBA16, colorSpace: pq)
            else { throw ExportError.encodingFailed("HDR PNG") }
            return data
        case .jpeg:
            // 1ch ゲインマップは CoreImage が base と hdr の差分から作る。
            let options: [CIImageRepresentationOption: Any] = [
                .hdrImage: Self.onWhite(alt), Self.qualityKey: lossyQuality,
            ]
            guard let data = context.jpegRepresentation(
                of: Self.onWhite(base), colorSpace: p3, options: options)
            else { throw ExportError.encodingFailed("HDR JPEG") }
            // 添付は成功しても、ゲインマップが入ったかを読み戻して確かめる。
            guard hasGainMap(data) else { throw ExportError.gainMapVerificationFailed }
            return data
        case .heic:
            return try heicWithColorGainMap(base: base, hdr: alt, context: context, baseColorSpace: p3)
        }
    }

    /// HDRForge の `writeColorGainMapHEIC` と同じ ImageIO 低レベル経路。
    /// ベースは RGBA16 の CGImage（ImageIO が 10bit＝HEVC Main 10 で書く）。`Depth` は渡さない
    /// （渡すと 16bit ベースでも 8bit に落ちる）。
    private static func heicWithColorGainMap(
        base: CIImage, hdr: CIImage, context: CIContext, baseColorSpace: CGColorSpace
    ) throws -> Data {
        guard let baseCG = context.createCGImage(
            base, from: base.extent, format: .RGBA16, colorSpace: baseColorSpace)
        else { throw ExportError.imageConversionFailed }
        let aux = try ColorGainMap.auxiliaryInfo(base: base, hdr: hdr, context: context)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.heic.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed("HDR HEIC") }
        CGImageDestinationAddImage(
            destination, baseCG,
            [kCGImageDestinationLossyCompressionQuality as String: lossyQuality] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(
            destination, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed("HDR HEIC") }

        // 添付は戻り値が無いので、書いた結果にカラーゲインマップがあるかを検算する。
        guard hasGainMap(data as Data) else { throw ExportError.gainMapVerificationFailed }
        guard ColorGainMap.isColorGainMap(data: data as Data) else { throw ExportError.colorGainMapFailed }
        return data as Data
    }

    // MARK: - 補助

    private static let qualityKey = CIImageRepresentationOption(
        rawValue: kCGImageDestinationLossyCompressionQuality as String)

    /// 透明部を白に敷く（JPEG はアルファを持てない）。
    private static func onWhite(_ image: CIImage) -> CIImage {
        image.composited(over: CIImage(color: .white).cropped(to: image.extent))
    }

    /// ISO ゲインマップ（または HDR の補助データ）を持つか。JPEG・HEIC 共通の検算。
    static func hasGainMap(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil { return true }
        }
        return false
    }
}
