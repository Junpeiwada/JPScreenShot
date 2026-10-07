import Foundation

// 種類ごとの「最後に使ったスタイル」の保存・読み込み（実装計画 P4-4）。
//
// AnnotationStyle は Codable なので、`[種類の rawValue: スタイル]` を JSON にして
// UserDefaults に 1 キーで持つ。読めない保存値は
// 無視して初期値に戻す（古い保存値で起動できなくならないように）。
// UserDefaults を差し替えられるようにしてあり、テストでは専用の suite を渡す。
struct AnnotationStyleStore {
    static let key = "annotationLastStyles"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存済みのスタイルを全部読む。壊れていれば空（初期値に戻る）。
    /// 知らない種類のキーは無視する。
    func loadAll() -> [AnnotationKind: AnnotationStyle] {
        guard let data = defaults.data(forKey: Self.key),
            let raw = try? JSONDecoder().decode([String: AnnotationStyle].self, from: data)
        else { return [:] }
        var result: [AnnotationKind: AnnotationStyle] = [:]
        for (name, style) in raw {
            if let kind = AnnotationKind(rawValue: name) { result[kind] = style }
        }
        return result
    }

    /// その種類の最後のスタイル。無ければ nil。
    func style(for kind: AnnotationKind) -> AnnotationStyle? {
        loadAll()[kind]
    }

    /// その種類の最後のスタイルを保存する（他の種類は保つ）。
    func save(_ style: AnnotationStyle, for kind: AnnotationKind) {
        var all = loadAll()
        all[kind] = style
        saveAll(all)
    }

    func saveAll(_ styles: [AnnotationKind: AnnotationStyle]) {
        let raw = Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// 保存値を消す（テスト・初期化用）。
    func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }
}
