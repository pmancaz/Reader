import SwiftUI
import PDFKit
import WebKit
import ReaderCore

@MainActor
final class ReaderBridge: ObservableObject {
    @Published var hasSelection = false
    @Published var pageNumber = 1
    @Published var pageCount = 0
    @Published var findText = ""
    @Published var notice: String?
    weak var pdfView: PDFView?
    weak var webView: WKWebView?
    var item: ReaderItem?
    var onProgress: ((String, ReadingProgress) -> Void)?
    var onAnnotation: ((ReaderAnnotation) -> Void)?
    var articleAnchors: [ReaderAnnotation] = []
    var isOriginal = false
    var pendingNavigation: ReaderAnnotation?
    var onRequestReader: (() -> Void)?

    func highlight(withNote: Bool = false) {
        guard !isOriginal else { notice = "Switch to Reader view to highlight a passage."; return }
        guard let item else { return }
        if item.kind == .pdf, let view = pdfView, let selection = view.currentSelection,
           let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var rects: [PDFAnchorRect] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let box = line.bounds(for: page)
                    guard let document = view.document, !box.isEmpty else { continue }
                    rects.append(PDFAnchorRect(pageIndex: document.index(for: page), x: box.origin.x, y: box.origin.y, width: box.width, height: box.height))
                }
            }
            guard !rects.isEmpty else { return }
            onAnnotation?(ReaderAnnotation(itemID: item.id, quote: text, note: withNote ? "Add your note…" : "", pdfRects: rects))
            view.clearSelection()
        } else if let webView {
            webView.evaluateJavaScript("window.ReaderAPI.selection()") { [weak self] result, error in
                guard let self, let values = result as? [String: Any], let exact = values["exact"] as? String, !exact.isEmpty else {
                    self?.notice = "Select a passage first."
                    return
                }
                guard self.item?.id == item.id else { return }
                let anchor = ArticleAnchor(exact: exact, prefix: values["prefix"] as? String ?? "", suffix: values["suffix"] as? String ?? "", start: values["start"] as? Int ?? 0, end: values["end"] as? Int ?? 0)
                self.onAnnotation?(ReaderAnnotation(itemID: item.id, quote: exact, note: withNote ? "Add your note…" : "", articleAnchor: anchor))
            }
        }
    }

    func navigate(to annotation: ReaderAnnotation) {
        if isOriginal { pendingNavigation = annotation; onRequestReader?(); return }
        if let rect = annotation.pdfRects.first, let view = pdfView, let page = view.document?.page(at: rect.pageIndex) {
            view.go(to: page)
            view.go(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).insetBy(dx: -12, dy: -40), on: page)
        } else if let webView, let data = try? JSONSerialization.data(withJSONObject: [annotation.id]), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.ReaderAPI.jump(\(json)[0])") { [weak self] found, _ in
                if found as? Bool == false { self?.notice = "This passage could not be located in the saved text." }
            }
        }
    }
    func resumeNavigation() {
        guard !isOriginal, let annotation = pendingNavigation else { return }
        pendingNavigation = nil
        if item?.id == annotation.itemID { navigate(to: annotation) }
    }
    func zoom(_ delta: Int) {
        guard let view = pdfView else { return }
        if delta > 0 { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }
    func goPage(_ page: Int) {
        guard let view = pdfView, let target = view.document?.page(at: max(0, min(page - 1, pageCount - 1))) else { return }
        view.go(to: target)
    }
    func rotate() {
        guard let view = pdfView, let page = view.currentPage else { return }
        page.rotation = (page.rotation + 90) % 360
        view.layoutDocumentView()
        if let item { let p = view.currentDestination?.point; onProgress?(item.id, ReadingProgress(fraction: item.progress.fraction, pageIndex: view.document?.index(for: page) ?? 0, zoom: view.scaleFactor, pageRotation: page.rotation, pdfX: p.map { Double($0.x) }, pdfY: p.map { Double($0.y) })) }
    }
    func find() {
        guard !findText.isEmpty else { return }
        if let view = pdfView, let document = view.document {
            let found = document.findString(findText, fromSelection: view.currentSelection, withOptions: [.caseInsensitive]) ?? document.findString(findText, withOptions: [.caseInsensitive]).first
            if let found { if let page = found.pages.first { view.go(to: page) }; view.setCurrentSelection(found, animate: true); view.go(to: found) }
            else { notice = "No matching text. Scanned PDFs may not have a text layer." }
        } else if let webView, let data = try? JSONSerialization.data(withJSONObject: [findText]), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.find(\(json)[0], false, false, true)") { [weak self] result, _ in
                if result as? Bool == false { self?.notice = "No matching text." }
            }
        }
    }
}

struct NativePDFReader: NSViewRepresentable {
    let url: URL
    let item: ReaderItem
    let annotations: [ReaderAnnotation]
    var original = false
    @ObservedObject var bridge: ReaderBridge
    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        bridge.pdfView = view
        bridge.webView = nil
        bridge.item = item
        bridge.isOriginal = original
        if context.coordinator.loaded != item.id {
            context.coordinator.loaded = item.id
            context.coordinator.signature = ""
            context.coordinator.restoring = true
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                context.coordinator.restoring = false
                bridge.notice = "The saved PDF could not be opened. Check that the library is available locally, or restore a backup."
                return
            }
            view.document = document
            bridge.pageCount = document.pageCount
            if let page = document.page(at: min(max(0, item.progress.pageIndex), document.pageCount - 1)) {
                let bounds = page.bounds(for: .cropBox)
                let y = item.progress.pdfY ?? (bounds.minY + (1 - item.progress.scrollFraction) * bounds.height)
                if item.progress.zoom > 0 { page.rotation = item.progress.pageRotation; view.autoScales = false; view.scaleFactor = item.progress.zoom }
                DispatchQueue.main.async {
                    view.go(to: PDFDestination(page: page, at: NSPoint(x: item.progress.pdfX ?? bounds.minX, y: y)))
                    // Navigation notifications were suppressed while restoring. Update
                    // the badge explicitly, without writing a new reading position.
                    bridge.pageNumber = document.index(for: page) + 1
                    context.coordinator.restoring = false
                }
            }
        }
        context.coordinator.apply(annotations, to: view)
        if !original, bridge.pendingNavigation != nil { DispatchQueue.main.async { bridge.resumeNavigation() } }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { coordinator.savePosition(view); coordinator.detach() }
    @MainActor final class Coordinator: NSObject {
        let bridge: ReaderBridge
        var loaded: String?
        var observers: [NSObjectProtocol] = []
        var signature = ""
        var restoring = false
        weak var view: PDFView?
        init(bridge: ReaderBridge) { self.bridge = bridge }
        func attach(_ view: PDFView) {
            self.view = view
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewSelectionChanged, .PDFViewScaleChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.bridge.hasSelection = !(view.currentSelection?.string ?? "").isEmpty
                        self.savePosition(view)
                    }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = view.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else { return }
                scroll.contentView.postsBoundsChangedNotifications = true
                self.observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.savePosition(view) } })
            }
        }
        func detach() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
        func savePosition(_ view: PDFView) {
            guard !restoring, let document = view.document, let page = view.currentDestination?.page ?? view.currentPage, loaded != nil else { return }
            let index = document.index(for: page)
            bridge.pageNumber = index + 1
            let center = view.currentDestination?.point ?? view.convert(CGPoint(x: view.bounds.minX, y: view.bounds.minY), to: page)
            let bounds = page.bounds(for: .cropBox)
            let fraction = min(1, max(0, 1 - ((center.y - bounds.minY) / bounds.height)))
            bridge.onProgress?(loaded!, ReadingProgress(fraction: fraction, pageIndex: index, zoom: view.scaleFactor, pageRotation: page.rotation, pdfX: center.x, pdfY: center.y))
        }
        func apply(_ annotations: [ReaderAnnotation], to view: PDFView) {
            let next = annotations.map { $0.id + $0.note + $0.quote }.joined()
            guard next != signature || signature.isEmpty else { return }
            signature = next
            guard let document = view.document else { return }
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                for annotation in page.annotations where annotation.userName == "Reader" { page.removeAnnotation(annotation) }
            }
            for saved in annotations {
                for rect in saved.pdfRects {
                    guard let page = document.page(at: rect.pageIndex) else { continue }
                    let annotation = PDFAnnotation(bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), forType: .highlight, withProperties: nil)
                    annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                    annotation.userName = "Reader"
                    annotation.contents = saved.note
                    page.addAnnotation(annotation)
                }
            }
        }
    }
}
