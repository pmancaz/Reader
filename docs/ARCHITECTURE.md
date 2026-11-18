# Architecture and deferred capture

Reader is a local macOS app. SwiftUI supplies library controls; PDFKit supplies rendering, text selection, native page coordinates and navigation. The offline WebKit reader renders saved article content. An explicitly selected Original view uses a separate ephemeral WebKit browser for the live website; it has no Reader script-message handlers or local-file read grants. Durable state belongs to ReaderCore and the configured library. Article extraction and network fetching belong to a reusable import pipeline rather than a particular button or window.

Article preparation uses Mozilla Readability followed by DOMPurify. Importing a page is distinct from showing it: the offline reader displays sanitised local content and cached assets. Live Original browsing does not modify this copy or its saved progress. A failed import must not overwrite an existing document. URL and PDF entry points should submit the same prepared-document job, so later capture methods do not need their own storage logic.

PDF annotations are records separate from the imported PDF. Their anchors contain item identity, page index and rectangles in PDF page space. PDFKit applies display zoom and page rotation. Imported originals remain unchanged; an annotated PDF should only be written by a separate explicit export operation. Article anchors preserve exact quote, prefix/suffix context and position hints, allowing repeated quotations to be disambiguated. If a later article edit invalidates an anchor, the quotation and note must remain available even if navigation cannot resolve it.

## Printing

Articles print through a separate offline WKWebView and WebKit's native multipage print operation, with a print stylesheet that removes screen-height/overflow constraints and sets A4 with 15 mm margins. The NSPrintInfo uses matching A4 defaults; WebKit needs the CSS page margins as well. PDFKit prints a fresh PDFDocument with scale-to-fit and automatic rotation, preserving page content. Neither path prints a screenshot of the scrollable reader or writes to managed originals. Both use asynchronous sheet-based NSPrintOperation execution; synchronous WebKit print execution is unsuitable here. The standard panel supplies preview, page selection and PDF saving. A4 is the default; printer/paper choices can be changed by the user.

## macOS Share extension

A real Share extension needs an Xcode app-extension target embedded under the app bundle’s `Contents/PlugIns`, an extension `Info.plist` with the Share extension point and appropriate activation rules, a supported minimum OS, and consistent code signing. It should accept `NSItemProvider` URL and PDF representations, copy temporary attachment data before the extension exits, and enqueue immutable import requests. Extraction, deduplication and final insertion should remain in the same import pipeline as the main app.

For a sandboxed extension, the Dropbox folder is not automatically available. A shared App Group container can hold a small capture queue; the main app drains it into the configured library. An App Group entitlement must be configured for both targets, with identifiers and provisioning/signing belonging to the same developer team. User-selected external-folder access may require security-scoped bookmarks and entitlements. Do not let the extension and main app write the library database concurrently. The extension should report queue success accurately and keep failed requests recoverable. No Share menu entry is shipped in this version.

## Watched inbox and email capture

A future watched folder can translate PDFs and small URL request files into durable import jobs, using stable request IDs and atomic moves to avoid partially written files. A separate email automation can create the same requests. Neither needs access to Reader’s database. The main app should record successful request IDs, preserve failures for retry, and never silently delete a source file before managed content is verified.

## Future iPhone/iPad and sync

Do not point multiple devices at one SQLite database in Dropbox. Each device should own its own local database and reducer. Synchronise immutable, content-addressed document objects plus immutable change records with stable device IDs, operation IDs and logical timestamps. Annotations retain independent IDs and anchors. Resolve edits explicitly using deterministic field rules or a visible conflict copy; use tombstones for deletion. Sync must be resumable and idempotent, and must not report an item as fully available offline until all referenced assets are local.

iPad apps are sandboxed. A desktop Dropbox path is not an iPad filesystem path; Dropbox’s Files provider exposes user-selected documents through coordinated, potentially transient access. A mobile version would need deliberate document-picker/provider integration and security-scoped access where supported, or a supported authenticated sync transport with explicit user consent. It must materialise content into its own sandbox and handle provider eviction, offline availability and background-execution limits. A Dropbox account should be an optional future sync transport, not a prerequisite for local reading.

## Primary references

- [Apple: PDFAnnotation](https://developer.apple.com/documentation/pdfkit/pdfannotation) — annotation bounds are page-space geometry.
- [Apple: PDFPage bounds](https://developer.apple.com/documentation/pdfkit/pdfpage/bounds(for:)) — page boxes and rotation.
- [Apple: configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) — shared containers and entitlement setup.
- [SQLite: Online Backup API](https://www.sqlite.org/c3ref/backup_finish.html) — consistent snapshots through SQLite’s supported API.
