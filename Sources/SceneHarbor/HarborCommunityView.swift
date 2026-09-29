import SwiftUI
import WebKit

struct HarborCommunityPage: Identifiable {
    let url: URL
    let creatorID: String?
    var id: String { url.absoluteString }
}

/// Community navigation stays in this sheet. Workshop item links are handed
/// back to the native inspector; new-window links never launch another app.
struct HarborCommunityView: View {
    let page: HarborCommunityPage
    let author: (String) -> Void
    let artwork: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Steam 社群", systemImage: "person.crop.circle")
                Spacer()
                if let creator = page.creatorID {
                    Button("瀏覽作者桌布") { dismiss(); author(creator) }.buttonStyle(.borderedProminent)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
            HarborCommunityWebView(url: page.url, author: { dismiss(); author($0) },
                                   artwork: { dismiss(); artwork($0) }, notice: { notice = $0 })
        }
    }
}

struct HarborCommunityWebView: NSViewRepresentable {
    let url: URL
    let author: (String) -> Void
    let artwork: (String) -> Void
    let notice: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    static func destination(_ url: URL) -> (artwork: String?, author: String?) {
        guard url.host?.lowercased() == "steamcommunity.com" else { return (nil, nil) }
        if url.path.contains("/sharedfiles/filedetails"),
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           !id.isEmpty, id.allSatisfy(\.isNumber) { return (id, nil) }
        let parts = url.pathComponents
        if parts.count >= 4, parts[1] == "profiles", parts[3] == "myworkshopfiles", parts[2].allSatisfy(\.isNumber) {
            return (nil, parts[2])
        }
        return (nil, nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HarborCommunityWebView
        init(_ parent: HarborCommunityWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, ["https", "http", "about"].contains(url.scheme?.lowercased() ?? "") else {
                parent.notice("此連結無法在 App 內開啟。"); decisionHandler(.cancel); return
            }
            // Keep the initial artwork page viewable; intercept user navigation.
            if action.navigationType == .linkActivated {
                let target = HarborCommunityWebView.destination(url)
                if let id = target.artwork { decisionHandler(.cancel); parent.artwork(id); return }
                if let id = target.author { decisionHandler(.cancel); parent.author(id); return }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url, ["https", "http"].contains(url.scheme ?? "") {
                let target = HarborCommunityWebView.destination(url)
                if let id = target.artwork { parent.artwork(id) }
                else if let id = target.author { parent.author(id) }
                else { webView.load(action.request) }
            }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.notice("頁面載入失敗：" + error.localizedDescription) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.notice(nil) }
    }
}
