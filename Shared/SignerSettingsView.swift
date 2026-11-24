import KaixinguoKit
import SwiftUI

/// SignerSettingsView is the settings: the signing service playback falls
/// back to when the built-in signing stops working. Saving checks that the
/// address answers as a signing service; saving again keeps one that did
/// not, as it may answer later.
struct SignerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var checking = false
    @State private var error = "" // why the service did not answer as one should
    @State private var unsure = false // saving again saves it all the same
    @State private var check: Task<Void, Never>?

    static let explanation = "红果改了签名校验时，内置签名可能暂时播不了。这时开心果会改用你部署的 openhongguo-signer 签名服务取播放地址，其他请求不经过它。不需要时留空。"

    var body: some View {
        let urlError = checkSignerURL(url)
        Form {
            Section {
                field("地址") {
                    TextField("地址", text: $url, prompt: Text(verbatim: "https://signer.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field("Token") {
                    SecureField("Token", text: $token, prompt: Text("签名服务没有设 token 时留空"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("签名服务")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !urlError.isEmpty {
                        Text(urlError).foregroundStyle(.red)
                    }
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                    Text(Self.explanation)
                }
            }
            .disabled(checking)
            #if os(tvOS)
            Section {
                Button(saveLabel) { save() }
                    .disabled(checking || !urlError.isEmpty)
                Button("取消", role: .cancel) { dismiss() }
            }
            #endif
        }
        .navigationTitle("设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if checking {
                    ProgressView()
                } else {
                    Button(saveLabel) { save() }
                        .disabled(!urlError.isEmpty)
                }
            }
        }
        #endif
        .onChange(of: url) { error = ""; unsure = false }
        .onChange(of: token) { error = ""; unsure = false }
        .onAppear {
            guard !loaded, let s = model.signing?.settings else { return }
            loaded = true
            url = s.url
            token = s.token
        }
        .onDisappear { check?.cancel() }
    }

    private var saveLabel: String {
        if checking { return "正在检查…" }
        return unsure ? "仍然保存" : "保存"
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        #if os(iOS)
        LabeledContent(label) { content().multilineTextAlignment(.trailing) }
        #else
        content()
        #endif
    }

    /// Checks that the service answers as one, then saves it and has
    /// playback fall back to it. A second save keeps one that did not.
    private func save() {
        let s = SignerSettings(url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                               token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.url.isEmpty || unsure {
            apply(s)
            return
        }
        checking = true
        error = ""
        check = Task {
            defer { checking = false }
            do {
                try await probeSigner(s.url, token: s.token)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                unsure = true
                return
            }
            guard !Task.isCancelled else { return }
            apply(s)
        }
    }

    private func apply(_ s: SignerSettings) {
        do {
            try model.signing?.apply(s)
            dismiss()
        } catch {
            self.error = "保存失败：" + friendly(error)
        }
    }
}
