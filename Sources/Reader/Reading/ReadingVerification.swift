import Foundation
import AppKit
import SwiftUI
import PDFKit
import CryptoKit
import ReaderCore

/// Opt-in, offline native verification. Never opens the personal default library.
@MainActor enum ReadingVerification {
    static func run() async -> Bool {
        let fm = FileManager.default
        let fixturePath = ProcessInfo.processInfo.environment["READER_FIXTURE_PDF"]
            ?? URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/reading-fixture.pdf").path
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let root = fm.temporaryDirectory.appendingPathComponent("ReaderPDFVerification-\(UUID().uuidString)")
        var count = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LibraryError.invalid("Verification failed: \(description)") }
            count += 1
            print("PASS: \(description)")
        }
        func near(_ first: CGRect, _ second: CGRect, tolerance: CGFloat = 0.2) -> Bool {
            abs(first.minX - second.minX) < tolerance && abs(first.minY - second.minY) < tolerance
                && abs(first.width - second.width) < tolerance && abs(first.height - second.height) < tolerance
        }
        func rectangle(_ value: PDFAnchorRect) -> CGRect {
            CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
        }
        do {
            let fixtureBytes = try Data(contentsOf: fixtureURL)
            let fixtureHash = ArticleImporter.hash(fixtureBytes)
            let importer = ArticleImporter()
            let prepared = try await importer.preparePDF(fileURL: fixtureURL)
            defer { prepared.cleanup() }
            let store = try LibraryStore(root: root, createIfMissing: true)
            defer { store.close() }
            let item = ReaderItem(title: "Reader PDF fixture", kind: .pdf, contentPath: prepared.contentPath,
                                  text: prepared.text, tags: ["verification"])
            try store.addItem(item, from: prepared.directory)
            let managed = try store.contentURL(for: item)
            let document = try required(PDFDocument(url: managed), "Managed PDF could not be opened")
            try check(document.pageCount == 3 && !document.isLocked, "Managed PDF opens offline with all three pages")
            let firstPage = try required(document.page(at: 0), "Missing first PDF page")
            let rotatedPage = try required(document.page(at: 1), "Missing rotated PDF page")
            try check(rotatedPage.rotation == 90, "Fixture includes a pre-rotated PDF page")

            let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.autoScales = false
            view.scaleFactor = 1
            view.document = document
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            view.layoutDocumentView()
            let bridge = ReaderBridge()
            bridge.item = item; bridge.pdfView = view; bridge.pageCount = document.pageCount
            let coordinator = NativePDFReader.Coordinator(bridge: bridge)
            coordinator.loaded = item.id
            coordinator.attach(view)
            defer { coordinator.detach() }
            var captured: ReaderAnnotation?
            var captureFailure: Error?
            bridge.onAnnotation = { annotation in
                do { try store.saveAnnotation(annotation); captured = annotation }
                catch { captureFailure = error }
            }
            var recordedProgress: ReadingProgress?
            bridge.onProgress = { id, value in
                recordedProgress = value
                do { try store.saveProgress(itemID: id, progress: value) }
                catch { captureFailure = error }
            }
            try await Task.sleep(nanoseconds: 100_000_000)

            let normalSelection = try required(document.findString("persimmon-1", withOptions: []).first, "No selectable text on page 1")
            view.setCurrentSelection(normalSelection, animate: false)
            bridge.highlight()
            if let captureFailure { throw captureFailure }
            var normal = try required(captured, "Highlight action did not create an annotation")
            normal.note = "A normal-page passage note"
            try store.saveAnnotation(normal)
            try check(normal.pdfRects.first?.pageIndex == 0 && normal.quote.contains("persimmon-1"), "Real PDF selection creates page-relative highlight and quoted passage")

            let rotatedSelection = try required(document.findString("persimmon-2", withOptions: []).first, "No selectable text on rotated page")
            captured = nil
            view.setCurrentSelection(rotatedSelection, animate: false)
            bridge.highlight(withNote: true)
            if let captureFailure { throw captureFailure }
            var rotated = try required(captured, "Rotated-page highlight was not captured")
            rotated.note = "A rotated-page passage note"
            try store.saveAnnotation(rotated)
            try check(rotated.pdfRects.first?.pageIndex == 1 && rotated.pdfRects.allSatisfy { $0.width > 0 && $0.height > 0 }, "Pre-rotated page selection produces usable page-space geometry")

            let combined = PDFSelection(document: document)
            combined.add(normalSelection)
            combined.add(rotatedSelection)
            view.setCurrentSelection(combined, animate: false)
            captured = nil
            bridge.highlight()
            if let captureFailure { throw captureFailure }
            let multi = try required(captured, "Multi-page highlight was not captured")
            try check(Set(multi.pdfRects.map(\.pageIndex)) == Set([0, 1]), "One selection preserves rectangles on multiple PDF pages")
            let saved = try store.annotations(itemID: item.id)
            coordinator.apply(saved, to: view)
            try check(firstPage.annotations.filter { $0.userName == "Reader" }.count >= 2
                && rotatedPage.annotations.filter { $0.userName == "Reader" }.count >= 2,
                "Native reader applies separately stored annotations on normal and rotated pages")

            let rect = try required(rotated.pdfRects.first, "Rotated annotation has no rectangle")
            let expected = rotatedSelection.bounds(for: rotatedPage)
            try check(near(rectangle(rect), expected), "Saved rotated-page rectangle matches the selected PDF text")
            for zoom in [0.75, 1.35, 2.0] {
                view.scaleFactor = zoom
                for rotation in [0, 90, 180, 270] {
                    rotatedPage.rotation = rotation
                    view.layoutDocumentView()
                    let textInView = view.convert(expected, from: rotatedPage)
                    let annotationInView = view.convert(rectangle(rect), from: rotatedPage)
                    let roundTrip = view.convert(annotationInView, to: rotatedPage)
                    try check(near(textInView, annotationInView) && near(roundTrip, expected),
                              "PDF highlight alignment holds at zoom \(zoom), rotation \(rotation)°")
                }
            }
            rotatedPage.rotation = 90
            view.scaleFactor = 1.3
            view.layoutDocumentView()
            bridge.navigate(to: rotated)
            try await Task.sleep(nanoseconds: 120_000_000)
            try check(view.currentPage === rotatedPage, "Annotation navigation returns to its PDF page")
            bridge.goPage(3)
            try await Task.sleep(nanoseconds: 120_000_000)
            try check(view.currentPage === document.page(at: 2), "Native PDF page controls navigate to requested page")
            bridge.findText = "persimmon-1"; bridge.find()
            try check(view.currentSelection?.string?.contains("persimmon-1") == true, "Native PDF search selects matching text")
            // Persist a nondefault position, rotation and zoom for the actual
            // representable restoration check below, rather than just the model.
            rotatedPage.rotation = 180
            view.scaleFactor = 1.45
            view.layoutDocumentView()
            view.go(to: rotatedPage)
            view.go(to: PDFDestination(page: rotatedPage, at: NSPoint(x: 300, y: 400)))
            try await Task.sleep(nanoseconds: 120_000_000)
            coordinator.savePosition(view)
            if let captureFailure { throw captureFailure }
            let progress = try required(recordedProgress, "Reader did not save PDF reading position")
            try check(progress.pageIndex == 1 && progress.pageRotation == 180 && abs(progress.zoom - 1.45) < 0.001,
                      "PDF reader saves a nondefault page, rotation and zoom")
            try check(ArticleImporter.hash(try Data(contentsOf: managed)) == fixtureHash
                && ArticleImporter.hash(try Data(contentsOf: fixtureURL)) == fixtureHash,
                "Highlighting, zooming and rotating leave original and managed PDF bytes unchanged")
            coordinator.detach()
            store.close()

            let reopened = try LibraryStore(root: root)
            defer { reopened.close() }
            let reopenedItem = try required(reopened.item(id: item.id), "PDF item missing after reopen")
            let persisted = try reopened.annotations(itemID: item.id)
            try check(persisted.count == 3 && persisted.first(where: { $0.id == rotated.id })?.pdfRects == rotated.pdfRects,
                      "PDF notes and multi-page anchor geometry persist after close/reopen")
            try check(reopenedItem.progress == progress, "PDF reading position and zoom persist after close/reopen")
            let reopenedDocument = try required(PDFDocument(url: try reopened.contentURL(for: reopenedItem)), "Cannot reopen local managed PDF")
            let reopenedView = PDFView(frame: view.frame)
            reopenedView.document = reopenedDocument
            let reopenedBridge = ReaderBridge(); reopenedBridge.item = reopenedItem; reopenedBridge.pdfView = reopenedView
            let reopenedCoordinator = NativePDFReader.Coordinator(bridge: reopenedBridge)
            reopenedCoordinator.loaded = item.id
            reopenedCoordinator.apply(persisted, to: reopenedView)
            let restoredPage = try required(reopenedDocument.page(at: 1), "Reopened rotated page missing")
            try check(restoredPage.rotation == 90 && restoredPage.annotations.contains(where: { $0.userName == "Reader" && near($0.bounds, expected) }),
                      "Reopened PDF reconstructs highlight at the original page-space location")

            // Exercise SwiftUI's makeNSView/updateNSView path itself. Constructing
            // a coordinator by hand cannot catch bugs in representable restore.
            let restorationBridge = ReaderBridge()
            let hostedReader = NSHostingView(rootView: NativePDFReader(
                url: try reopened.contentURL(for: reopenedItem), item: reopenedItem,
                annotations: persisted, bridge: restorationBridge))
            hostedReader.frame = view.frame
            let hostWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            hostWindow.contentView = hostedReader
            defer { hostWindow.orderOut(nil) }
            hostedReader.layoutSubtreeIfNeeded()
            for _ in 0..<25 {
                if restorationBridge.pdfView?.document != nil && restorationBridge.pageNumber == 2 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let actualRestoredView = try required(restorationBridge.pdfView, "SwiftUI did not create the native PDF reader")
            let actualRestoredDocument = try required(actualRestoredView.document, "SwiftUI did not load the managed PDF")
            let actualRestoredPage = try required(actualRestoredDocument.page(at: 1), "SwiftUI-restored PDF page missing")
            try check(actualRestoredView.currentPage === actualRestoredPage
                && actualRestoredView.currentDestination?.page === actualRestoredPage,
                      "Hosted native representable restores the actual saved PDF page")
            try check(actualRestoredPage.rotation == 180 && abs(actualRestoredView.scaleFactor - progress.zoom) < 0.001,
                      "Hosted native representable restores saved page rotation and zoom")
            try check(restorationBridge.pageNumber == 2 && restorationBridge.pageCount == 3,
                      "Hosted native representable updates the page badge after restoration")
            if let destination = actualRestoredView.currentDestination, let x = progress.pdfX, let y = progress.pdfY {
                try check(abs(destination.point.x - x) < 1 && abs(destination.point.y - y) < 1,
                          "Hosted native representable restores the saved PDF destination point")
            } else { throw LibraryError.invalid("Restored PDF destination point is missing") }
            try check(actualRestoredPage.annotations.contains(where: { $0.userName == "Reader" && near($0.bounds, expected) }),
                      "Hosted restored PDF retains its passage highlight")
            reopened.close()

            let model = AppModel()
            model.openLibrary(root)
            defer { model.store?.close() }
            model.select(item.id)
            var horizontalProgress = ReadingProgress(fraction: 0.4, pageIndex: 1, zoom: 1.45, pageRotation: 180, pdfX: 100, pdfY: 400)
            model.progress(id: item.id, value: horizontalProgress)
            horizontalProgress.pdfX = 180
            model.progress(id: item.id, value: horizontalProgress)
            let storedHorizontal = try required(try model.store?.item(id: item.id), "PDF position missing after horizontal scroll")
            try check(storedHorizontal.progress.pdfX == 180 && storedHorizontal.progress.pdfY == 400,
                      "Horizontal-only PDF movement reaches persistent storage with unchanged page, fraction, zoom and rotation")
            var metadata = try required(model.selectedItem, "App model did not reopen the PDF")
            metadata.title = "Verification edited PDF"; metadata.tags = ["quiet", "persimmon"]
            metadata.isFavorite = true; metadata.isArchived = true; metadata.status = .finished
            model.update(metadata)
            model.section = .archive
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Archive status is reflected in the library view")
            model.section = .favorites
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Favourite filter includes the edited item")
            model.query = "rotated-page passage"
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Library search finds passage-note text")
            model.query = "Verification edited persimmon"
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Library search combines title and tags")
            metadata.trashedAt = Date(); model.update(metadata)
            model.query = ""; model.section = .all
            try check(!model.visibleItems.contains(where: { $0.id == item.id }), "Trashed item leaves the active library")
            model.section = .trash
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Trash keeps the item recoverable")
            metadata.trashedAt = nil; model.update(metadata)
            model.section = .all
            try check(model.visibleItems.contains(where: { $0.id == item.id }), "Restoring from Trash returns the same stable item")
            let general = ReaderAnnotation(itemID: item.id, note: "General document note: marigold")
            model.save(general)
            try check(model.flushPending() && model.pendingAnnotations.isEmpty, "General document notes flush through the app model")
            model.store?.close()
            let final = try LibraryStore(root: root)
            defer { final.close() }
            let finalItem = try required(final.item(id: item.id), "Final item missing")
            try check(finalItem.title == metadata.title && finalItem.tags == metadata.tags && finalItem.isArchived && finalItem.isFavorite && finalItem.trashedAt == nil,
                      "Title, tags, favourite, archive and restored-trash state persist")
            try check(try final.search("marigold").contains(where: { $0.id == item.id }), "General notes remain searchable after restart")
            print("READING VERIFICATION PASSED: \(count) checks. Temporary library: \(root.path)")
            return true
        } catch {
            print("READING VERIFICATION FAILED: \(error.localizedDescription)")
            print("Temporary library, if created: \(root.path)")
            return false
        }
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw LibraryError.invalid(message) }
        return value
    }
}
