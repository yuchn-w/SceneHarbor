import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HarborLoginView: View {
    @ObservedObject var steam: SteamServiceBridge
    @Environment(\.dismiss) private var dismiss
    @State private var username = UserDefaults.standard.string(forKey: "SceneHarborSteamUsername") ?? ""
    @State private var password = ""
    @State private var code = ""
    @AppStorage("SceneHarborRememberSteamSession") private var remember = true
    private var busy: Bool { !["loggedIn", "loggedOut", "failed"].contains(steam.authState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HarborSheetHeader(title: "連接 Steam", symbol: "person.crop.circle", subtitle: "同步訂閱與收藏，下載喜歡的桌布。", padding: 0, dismiss: { dismiss() })
            if steam.isLoggedIn {
                Label("已登入：\(steam.accountName)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("登出 Steam") { steam.logout() }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 12) {
                        if let url = steam.challengeURL, let image = qrImage(url.absoluteString) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 164, height: 164).padding(8).background(.white)
                            Text("使用 Steam 手機 App 掃描").font(.caption)
                        } else {
                            Image(systemName: "qrcode").font(.system(size: 74)).foregroundStyle(.secondary).frame(width: 180, height: 180)
                        }
                        Button("使用 QR 登入") { steam.loginWithQR(rememberSession: remember) }.disabled(busy)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("或使用帳號密碼").font(.headline)
                        TextField("Steam 帳號", text: $username)
                        SecureField("密碼", text: $password)
                        Button("登入") {
                            steam.login(username: username, password: password, rememberSession: remember)
                            password = ""
                        }.buttonStyle(.borderedProminent).disabled(username.isEmpty || password.isEmpty || busy)
                        Toggle("保持登入", isOn: $remember)
                        Text("密碼只用於本次登入；保持登入使用 macOS 鑰匙圈。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder)
                }
                if ["mobileCode", "emailCode"].contains(steam.authState) {
                    HStack {
                        TextField("Steam Guard 驗證碼", text: $code).textFieldStyle(.roundedBorder)
                        Button("送出") { steam.submitChallenge(code); code = "" }.disabled(code.isEmpty)
                    }
                }
                if busy { HStack { ProgressView().controlSize(.small); Button("取消登入") { steam.cancelLogin() } } }
                Text(steam.challengeMessage.isEmpty ? steam.state : steam.challengeMessage)
                    .font(.caption).textSelection(.enabled).foregroundStyle(steam.authState == "failed" ? Color.orange : Color.secondary)
            }
            Spacer()
        }.padding(26).onAppear { steam.start() }
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
