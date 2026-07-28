import AppKit
import SwiftUI

// 環境設定（要求 4.1 / CPY-04 / SAV-04）。
//
// 第 1 版で扱う設定は 3 つだけに絞る。
// - 認識モードの既定（6.3「直前に使ったモードを記憶する」の確認・変更用）
// - コピー後にウィンドウを閉じるか（CPY-04）
// - 画像の保存先（SAV-04「環境設定で変更できることが望ましい」）
struct SettingsView: View {
    @State private var mode: RecognitionMode
    @State private var closeAfterCopy: Bool
    @State private var saveDirectory: URL

    init() {
        let settings = Settings.shared
        _mode = State(initialValue: settings.recognitionMode)
        _closeAfterCopy = State(initialValue: settings.closeAfterCopy)
        _saveDirectory = State(initialValue: settings.saveDirectory)
    }

    var body: some View {
        Form {
            Section("認識") {
                Picker("認識モード", selection: $mode) {
                    ForEach(RecognitionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: mode) { _, new in
                    Settings.shared.recognitionMode = new
                }

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("結果ウィンドウ") {
                Toggle("コピーしたらウィンドウを閉じる", isOn: $closeAfterCopy)
                    .onChange(of: closeAfterCopy) { _, new in
                        Settings.shared.closeAfterCopy = new
                    }
                Text("オフのままなら、閉じるのは「閉じる」ボタンか Esc だけになります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("保存") {
                HStack {
                    // 保存先はパスが長くなるので末尾を優先して見せる。
                    Text(saveDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("変更…") { chooseDirectory() }
                    if saveDirectory != Settings.desktopDirectory {
                        Button("デスクトップに戻す") {
                            saveDirectory = Settings.desktopDirectory
                            Settings.shared.saveDirectory = saveDirectory
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modeDescription: String {
        switch mode {
        case .japanese:
            "文章・UI テキスト向け。日本語と英語を認識します。"
        case .code:
            "ソースコードやエラーメッセージ向け。英語のみで認識し、全角記号を半角に直します。"
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDirectory
        panel.prompt = "選択"
        panel.message = "キャプチャ画像の保存先を選んでください。"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveDirectory = url
        Settings.shared.saveDirectory = url
    }
}
