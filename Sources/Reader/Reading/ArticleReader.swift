import SwiftUI
import WebKit
import ReaderCore

struct ArticleReader: NSViewRepresentable {
    let url: URL
    let item: ReaderItem
    let annotations: [ReaderAnnotation]
    let fontSize: Double
    let lineSpacing: Double
    let readingWidth: Double
    let dark: Bool
    @ObservedObject var bridge: ReaderBridge
    func makeCoordinator() -> Coordinator { Coordinator(bridge) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let scriptURL = ReaderResources.bundle.url(forResource: "Reader", withExtension: "js", subdirectory: "Resources")!
        let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "reader")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        bridge.webView = view; bridge.pdfView = nil; bridge.item = item
        bridge.isOriginal = false
        coordinator.appearance = [fontSize, lineSpacing, readingWidth, dark]
        coordinator.annotations = annotations
        if coordinator.loaded != item.id {
            coordinator.loaded = item.id
            coordinator.fraction = item.progress.fraction
            coordinator.ready = false
            coordinator.allowedDirectory = url.deletingLastPathComponent().standardizedFileURL
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if coordinator.ready { coordinator.update() }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        view.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let bridge: ReaderBridge
        weak var web: WKWebView?
        var loaded: String?
        var allowedDirectory: URL?
        var appearance: [Any] = []
        var annotations: [ReaderAnnotation] = []
        var fraction: Double = 0
        var ready = false
        var rendering = ""
        var styling = ""
        init(_ bridge: ReaderBridge) { self.bridge = bridge }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
            if type == "selection" { bridge.hasSelection = payload["selected"] as? Bool ?? false }
            if type == "progress", ready, let f = payload["fraction"] as? Double, let id = loaded { bridge.onProgress?(id, ReadingProgress(fraction: f)) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            rendering = ""; styling = ""; ready = true
            update()
            webView.evaluateJavaScript("window.ReaderAPI.restore(\(fraction))") { [weak self] _, _ in self?.bridge.resumeNavigation() }
        }
        func update() {
            guard let web else { return }
            if let data = try? JSONSerialization.data(withJSONObject: appearance), let json = String(data: data, encoding: .utf8), json != styling {
                styling = json; web.evaluateJavaScript("window.ReaderAPI.appearance(...\(json))")
            }
            if let data = try? JSONEncoder().encode(annotations), let json = String(data: data, encoding: .utf8), json != rendering {
                rendering = json; web.evaluateJavaScript("window.ReaderAPI.render(\(json))")
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if url.isFileURL, url.deletingLastPathComponent() == allowedDirectory, url.fragment != nil { decisionHandler(.allow); return }
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel); return
            }
            if url.isFileURL, let allowedDirectory, url.standardizedFileURL.path.hasPrefix(allowedDirectory.path + "/") { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { bridge.notice = error.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { bridge.notice = error.localizedDescription }
    }
}
