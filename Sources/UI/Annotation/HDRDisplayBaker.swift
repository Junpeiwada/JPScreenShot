import CoreImage

// HDR 版（拡張 sRGB・half float）を、画面で HDR(EDR) として出せる CGImage に焼く。
//
// HDRForge の知見（知見-GUI 3）:
// - HDR 表示の条件は ITU-R 2100 PQ 色空間で焼くこと。拡張 Display P3 のままだと、
//   他者の EDR に相乗りして光って見えるだけで、窓構成の変化で SDR に落ちる。
// - `calculateHDRStats: true` が無いと contentHeadroom が付かず、`.high` の要求が無視される。
enum HDRDisplayBaker {

    /// 共有の CIContext（生成が重いので使い回す。スレッドセーフ）。
    /// 作業空間は拡張リニア sRGB・half float。8bit や sRGB クランプだと 1.0 超が潰れる。
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh.rawValue,
    ])

    /// PQ・16bit・HDR 統計付きの CGImage を作る。失敗したら nil（呼び出し側は SDR のままにする）。
    static func bake(_ hdr: CGImage) -> CGImage? {
        guard let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else { return nil }
        let image = CIImage(cgImage: hdr)
        return context.createCGImage(
            image, from: image.extent, format: .RGBA16, colorSpace: pq,
            deferred: false, calculateHDRStats: true)
    }
}
