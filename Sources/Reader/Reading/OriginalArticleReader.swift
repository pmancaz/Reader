import SwiftUI
import WebKit
import ReaderCore

enum ReadingPresentation: String, CaseIterable { case reader = "Reader", original = "Original" }

/// Live website content has an ephemeral browser and no Reader message handlers or file grants.
@MainActor final class OriginalPageController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private(set) var web: WKWebView?
    private var loadedID: String?
    static func canLoad(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    func makeView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        web = view; loadedID = nil
        return view
    }
    func load(_ item: ReaderItem) {
        guard loadedID != item.id, let web else { return }
        loadedID = item.id
        error = nil; canGoBack = false; canGoForward = false
        guard let value = item.originalURL, let url = URL(string: value), Self.canLoad(url) else {
            error = "This article has no original website address. The saved Reader copy is still available."
            isLoading = false; return
        }
        currentURL = url; isLoading = true
        web.load(URLRequest(url: url))
    }
    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func reload() {
        guard let web, let url = currentURL, Self.canLoad(url) else { return }
        error = nil; isLoading = true
        if web.url != nil { web.reload() } else { web.load(URLRequest(url: url)) }
    }
    func close(_ view: WKWebView) { view.stopLoading(); view.navigationDelegate = nil; if web === view { web = nil; loadedID = nil } }
    private func update(_ view: WKWebView) {
        currentURL = view.url ?? currentURL
        canGoBack = view.canGoBack; canGoForward = view.canGoForward
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard Self.canLoad(url) else {
            if action.navigationType == .linkActivated, url.scheme == "mailto" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        if action.targetFrame == nil, action.navigationType == .linkActivated { webView.load(action.request); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = nil; isLoading = true; update(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false; update(webView) }
    private func failed(_ failure: Error, view: WKWebView) {
        if (failure as NSError).code == NSURLErrorCancelled { return }
        isLoading = false; error = "The original website could not be loaded. Check your connection or open it in your browser.\n\n" + failure.localizedDescription
        update(view)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, view: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, view: webView) }
}

struct OriginalArticleReader: NSViewRepresentable {
    let item: ReaderItem
    @ObservedObject var controller: OriginalPageController
    @ObservedObject var bridge: ReaderBridge
    func makeCoordinator() -> OriginalPageController { controller }
    func makeNSView(context: Context) -> WKWebView { controller.makeView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        bridge.webView = view; bridge.pdfView = nil; bridge.item = item; bridge.isOriginal = true
        DispatchQueue.main.async { if controller.web === view { controller.load(item) } }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: OriginalPageController) { coordinator.close(view) }
}
