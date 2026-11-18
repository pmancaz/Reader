import AppKit
import WebKit
import PDFKit
import ReaderCore

/// Print the document, never a screenshot of the scrollable reading pane.
@MainActor final class DocumentPrinter: NSObject, ObservableObject {
    @Published private(set) var isBusy = false
    var onError: ((String) -> Void)?
    private var prepared: PreparedPrint?

    static func a4PrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperName = NSPrinter.PaperName("A4")
        info.paperSize = NSSize(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
        info.orientation = .portrait
        let margin = 15 * 72 / 25.4
        info.leftMargin = margin; info.rightMargin = margin
        info.topMargin = margin; info.bottomMargin = margin
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.scalingFactor = 1
        info.jobDisposition = .spool
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return info
    }

    func printDocument(_ item: ReaderItem, url: URL, window: NSWindow) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                let prepared = try await Self.prepare(item, url: url)
                self.prepared = prepared
                let operation = prepared.operation
                operation.showsPrintPanel = true
                operation.showsProgressPanel = true
                operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
                operation.runModal(for: window, delegate: self,
                                   didRun: #selector(printDidFinish(_:success:contextInfo:)), contextInfo: nil)
            } catch {
                isBusy = false
                onError?("Reader could not prepare this document for printing.\n\n" + error.localizedDescription)
            }
        }
    }

    @objc private func printDidFinish(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        prepared = nil; isBusy = false
    }

    static func prepare(_ item: ReaderItem, url: URL, printInfo: NSPrintInfo? = nil) async throws -> PreparedPrint {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw LibraryError.io("The saved file is unavailable. Make the library available offline and try again.")
        }
        let info = printInfo ?? a4PrintInfo()
        if item.kind == .pdf {
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
                  let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
                throw LibraryError.io("The saved PDF could not be opened for printing.")
            }
            operation.jobTitle = item.title
            return PreparedPrint(operation: operation, document: document)
        }
        let article = PrintArticleSession()
        try await article.load(url)
        let operation = article.web.printOperation(with: info)
        // WebKit can return a zero-frame printing view on newer macOS versions.
        // Give it real bounds before AppKit asks it for pagination/preview.
        operation.view?.frame = article.web.bounds
        operation.jobTitle = item.title
        return PreparedPrint(operation: operation, article: article)
    }
}

@MainActor final class PreparedPrint {
    let operation: NSPrintOperation
    private let article: PrintArticleSession?
    private let document: PDFDocument?
    init(operation: NSPrintOperation, article: PrintArticleSession? = nil, document: PDFDocument? = nil) {
        self.operation = operation; self.article = article; self.document = document
    }
}

/// A separate, offline view keeps print styles and pagination out of the reading view.
@MainActor final class PrintArticleSession: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var directory: URL?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 960), configuration: config)
        super.init()
        web.navigationDelegate = self
    }
    func load(_ url: URL) async throws {
        directory = url.deletingLastPathComponent().standardizedFileURL
        defer { timeout?.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.web.stopLoading()
                self?.finish(.failure(LibraryError.io("Preparing the print layout timed out. Try again.")))
            }
        }
        guard let cssURL = ReaderResources.bundle.url(forResource: "Print", withExtension: "css", subdirectory: "Resources") else {
            throw LibraryError.io("The print stylesheet is missing. Rebuild Reader.")
        }
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        _ = try await web.callAsyncJavaScript("""
        const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);
        for (const figure of document.querySelectorAll('figure')) {
          const heading = figure.previousElementSibling;
          if (heading && /^H[1-6]$/.test(heading.tagName)) figure.prepend(heading);
        }
        await document.fonts.ready;
        await Promise.all([...document.images].map(img => Promise.race([
          img.decode().catch(() => {}), new Promise(resolve => setTimeout(resolve, 3000))
        ])));
        return true;
        """, arguments: ["css": css], in: nil, contentWorld: .page)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url.map { $0.isFileURL && $0.standardizedFileURL.path.hasPrefix((directory?.path ?? "") + "/") } ?? false
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Void, Error>) { let next = pending; pending = nil; next?.resume(with: result) }
}
