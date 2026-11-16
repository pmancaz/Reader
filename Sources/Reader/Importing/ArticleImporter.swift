import Foundation
import CoreFoundation
import WebKit
import PDFKit
import CryptoKit
import ReaderCore

/// A staged, self-contained import. Commit through LibraryStore.addItem, then call cleanup().
/// No file in this directory is an authoritative copy until the store commits it.
struct PreparedImport {
    let title: String
    let author: String?
    let originalURL: String?
    let kind: ItemKind
    let text: String
    let directory: URL
    let contentPath: String
    let contentHash: String
    let warnings: [String]
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

enum ImportFailure: LocalizedError {
    case invalidURL, http(Int), unsupported(String), tooLarge, emptyPDF, noArticle, invalidEncoding, extraction(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use a complete http:// or https:// URL."
        case .http(let status): return "The server returned HTTP \(status). Open the original page or retry later. Reader cannot sign in or bypass access restrictions."
        case .unsupported(let type): return "This address returned \(type), which Reader cannot import. Use a web article or PDF."
        case .tooLarge: return "This download is too large (maximum 100 MB for a PDF, 12 MB for an article)."
        case .emptyPDF: return "The file is not a readable, unlocked PDF. Encrypted PDFs must be unlocked before import."
        case .noArticle: return "No substantial readable article was found. The page may require JavaScript, a login, or a subscription. Open the original or retry a direct article URL."
        case .invalidEncoding: return "The page text could not be decoded. Try importing a PDF version."
        case .extraction(let message): return "Article extraction failed: \(message)"
        }
    }
}

/// Reusable capture boundary for URL entry, file drops, and future native share entry points.
/// Network I/O is asynchronous. Page scripts are never loaded or executed.
@MainActor
final class ArticleImporter {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: config)
    }

    func prepare(url: URL) async throws -> PreparedImport {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw ImportFailure.invalidURL }
        let (data, response) = try await Self.download(url, session: session, maximumBytes: 100 * 1024 * 1024)
        let finalURL = response.url ?? url
        let mime = response.mimeType?.lowercased() ?? ""
        if mime == "application/pdf" || data.starts(with: Data("%PDF-".utf8)) {
            return try await stagePDF(data: data, suggestedName: finalURL.deletingPathExtension().lastPathComponent,
                                      originalURL: finalURL.absoluteString)
        }
        guard data.count <= 12 * 1024 * 1024 else { throw ImportFailure.tooLarge }
        guard mime.isEmpty || ["text/html", "application/xhtml+xml"].contains(mime) else {
            throw ImportFailure.unsupported(mime)
        }
        var encoding: String.Encoding = .utf8
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportFailure.invalidEncoding
        }
        return try await prepareHTML(html, originalURL: finalURL)
    }

    func preparePDF(fileURL: URL) async throws -> PreparedImport {
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1024 * 1024 else { throw ImportFailure.tooLarge }
        let name = fileURL.deletingPathExtension().lastPathComponent
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: fileURL, options: .mappedIfSafe) }.value
        return try await stagePDF(data: data, suggestedName: name, originalURL: nil)
    }

    /// Also used by deterministic fixture verification; does not fetch the source page.
    func prepareHTML(_ html: String, originalURL: URL) async throws -> PreparedImport {
        let result = try await ExtractionSession().extract(html: html, url: originalURL)
        guard let title = result["title"] as? String,
              let body = result["html"] as? String, let text = result["text"] as? String,
              text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 else { throw ImportFailure.noArticle }
        let directory = try stagingDirectory()
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
            var savedBody = body
            var warnings: [String] = []
            let images = result["images"] as? [[String: String]] ?? []
            for (index, image) in images.enumerated() {
                let token = "reader-image-\(index)"
                guard let source = image["url"], let imageURL = URL(string: source),
                      ["http", "https"].contains(imageURL.scheme?.lowercased() ?? "") else { continue }
                do {
                    let (data, response) = try await Self.download(imageURL, session: session, maximumBytes: 8 * 1024 * 1024)
                    let mime = response.mimeType?.lowercased() ?? ""
                    let formats = ["image/jpeg":"jpg", "image/png":"png", "image/gif":"gif", "image/webp":"webp", "image/avif":"avif"]
                    guard let ext = formats[mime] else { throw ImportFailure.unsupported(mime) }
                    let path = "images/\(index).\(ext)"
                    try data.write(to: directory.appendingPathComponent(path), options: .atomic)
                    savedBody = savedBody.replacingOccurrences(of: "src=\"\(token)\"", with: "src=\"\(path)\"")
                } catch {
                    warnings.append("An image could not be cached: \(imageURL.host ?? "source").")
                    // No remote fallback: opening a saved article never initiates a network request.
                    savedBody = savedBody.replacingOccurrences(of: "src=\"\(token)\"", with: "data-unavailable=\"offline image unavailable\"")
                }
            }
            let document = Self.wrap(body: savedBody, title: title)
            let bytes = Data(document.utf8)
            try bytes.write(to: directory.appendingPathComponent("article.html"), options: .atomic)
            return PreparedImport(title: title, author: result["author"] as? String,
                                  originalURL: originalURL.absoluteString, kind: .article, text: text,
                                  directory: directory, contentPath: "article.html", contentHash: Self.hash(bytes), warnings: warnings)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    nonisolated private static func download(_ url: URL, session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Reader/1.0 (personal offline reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/pdf,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportFailure.unsupported("an invalid response") }
        guard (200...299).contains(http.statusCode) else { throw ImportFailure.http(http.statusCode) }
        guard ["https", "http"].contains(response.url?.scheme?.lowercased() ?? "") else { throw ImportFailure.invalidURL }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw ImportFailure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw ImportFailure.tooLarge }
            if data.count % 262144 == 0 { try Task.checkCancellation() }
        }
        return (data, response)
    }

    private func stagePDF(data: Data, suggestedName: String, originalURL: String?) async throws -> PreparedImport {
        let metadata = try await Task.detached(priority: .userInitiated) { () -> (String, String?, String, String) in
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ImportFailure.emptyPDF }
            let attributes = document.documentAttributes ?? [:]
            let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title?.isEmpty == false ? title! : (suggestedName.isEmpty ? "Untitled PDF" : suggestedName),
                    attributes[PDFDocumentAttribute.authorAttribute] as? String, document.string ?? "", Self.hash(data))
        }.value
        let directory = try stagingDirectory()
        do {
            try data.write(to: directory.appendingPathComponent("original.pdf"), options: .atomic)
            return PreparedImport(title: metadata.0, author: metadata.1, originalURL: originalURL,
                                  kind: .pdf, text: metadata.2, directory: directory,
                                  contentPath: "original.pdf", contentHash: metadata.3, warnings: [])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func wrap(body: String, title: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(safeTitle)</title><style>:root{color-scheme:light dark}body{font:19px/1.7 Georgia,serif;margin:0 auto;padding:48px 40px;max-width:720px;color:#282828;background:#fbfaf7}h1{font-size:2em;line-height:1.2;margin-top:0}h2,h3,h4{line-height:1.3}img{max-width:100%;height:auto}a{color:#507a91}blockquote{border-left:3px solid #a6a6a6;margin-left:0;padding-left:1.25em}pre{overflow-x:auto;white-space:pre-wrap}table{border-collapse:collapse;max-width:100%;display:block;overflow-x:auto}td,th{border:1px solid #8885;padding:6px}mark{background:#f0d770;color:#252525}img:not([src]){display:none}@media(prefers-color-scheme:dark){body{background:#212121;color:#e6e3dd}a{color:#9ac3dc}}</style></head><body><h1>\(safeTitle)</h1><main id="reader-content">\(body)</main></body></html>
        """
    }
}

@MainActor
private final class ExtractionSession: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    func extract(html: String, url: URL) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        defer { timeout?.cancel(); view.stopLoading(); view.navigationDelegate = nil; webView = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            view.loadHTMLString("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'none'; script-src 'none'\"><title>Reader extraction</title>", baseURL: nil)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ImportFailure.extraction("The extraction engine timed out. Retry the import.")))
            }
        }
        var code = ""
        for name in ["Readability.js", "purify.min.js", "extract.js"] {
            guard let resource = ReaderResources.bundle.url(forResource: name, withExtension: nil, subdirectory: "Resources") else { throw ImportFailure.extraction("Missing bundled \(name). Rebuild the app.") }
            code += try String(contentsOf: resource, encoding: .utf8) + "\n"
        }
        code += "return extractReaderArticle(sourceHTML, sourceURL);"
        let result = try await view.callAsyncJavaScript(code, arguments: ["sourceHTML": html, "sourceURL": url.absoluteString], in: nil, contentWorld: .page)
        guard let result = result as? [String: Any] else { throw ImportFailure.noArticle }
        return result
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Void, Error>) { let pending = continuation; continuation = nil; pending?.resume(with: result) }
}
