# Verification record

16 November 2026, Australia/Sydney. Apple Silicon (`arm64`), Apple Swift 6.4.2 and Command Line Tools. Tests use new temporary libraries and local fixtures; no destructive test runs against the personal default library.

## Automated results

The final source passed **108 checks across six suites**:

| Suite | Passed | Evidence |
| --- | ---: | --- |
| Storage | 8/8 | Content, metadata, notes/progress after reopen; title/body/note search; transactions; single writer; missing/partial/invalid library rejection; conflict protection; pre-migration snapshots; corruption rejection; Markdown export; narration version/playback preservation and separate restore. |
| Model-free narration rules | 3/3 | UTF-16 citation edits preserve emoji and surrounding prose; cleanup/reference switches remain independent; invalid ranges cannot truncate author text. |
| PDF extraction preservation | 4/4 | Rotated middle-page inclusion; partial-layout fallback; page order across 0/90/180/270-degree rotations; unchanged originals and explicit no-text-page notice. |
| Article import and WebKit | 23/23 | Redirect/final URL; sanitisation; cached raster image and missing-image warning; PDF URL detection and intact file copy; HTTP 503 and unsupported-content failure; repeated-quote context/position anchors; navigation; light/dark typography; duplicate URL; notes/progress after reopen; complete export/restore. |
| Native PDF and library model | 43/43 | Real normal/pre-rotated/multi-page PDF selection; twelve zoom/rotation combinations; exact-page navigation; search; unchanged source/managed PDF hashes; persistent geometry; actual SwiftUI representable restoration of page, rotation, zoom, badge and destination point; horizontal-only movement persisted; title/tags/favourite/archive/trash/restore and note search. |
| Native local narration | 27/27 | Actual app controller launches local DeBERTa cleanup, Kokoro speech and MP3 encoding for article and PDF; AVAudioPlayer decoding; app-model completion callback; seek/resume including a stale item; cancellation and failed replacement preserve prior MP3; PDF source hashes; provenance; all three source-page passages retained in both extracted and spoken text; reopen; complete audio export/restore. |

`./scripts/verify.sh` runs the first five suites, **81 checks**. The last complete baseline run passed 80 checks; the final horizontal-position regression then passed in the impacted 43-check native reading suite, with unrelated suites unchanged. The corrected packaged debug app’s `--verify-narration` run passed **27 checks** separately using actual inference, not mock audio. `./scripts/verify.sh --narration` runs all six suites reproducibly.

The storage narration test uses synthetic MP3 bytes to isolate preservation logic; the 27 native narration checks create and decode real audio. PDF alignment assertions compare actual text and highlight rectangles through PDFView transforms, with manual visual checks in addition. Database close/reopen tests are supplemented by the full-process restart check below.

## Offline and recovery

- A reopened saved article and its cached image rendered with all HTTP/HTTPS requests blocked in WebKit. Native PDF verification reopens local managed files without a network request.
- The separate R2M worker completed real narration with network access denied. Inference uses local model paths and offline/telemetry-disabled flags.
- Complete-library exports were restored into separate absent temporary destinations, then content, notes, anchors, metadata and narration bytes/provenance were checked. Corrupt snapshots were rejected without touching the live library.
- Source and managed PDFs remained byte-for-byte unchanged after PDF highlighting, zoom, viewing rotation, layout-aware extraction and narration.
- Failed/cancelled narration kept previous audio and retained failed staged work for recovery.

## Packaging

`./scripts/build.sh release` completed: `build/Reader.app` (approximately 1.1 GB including local inference dependencies), Mach-O `arm64`, local ad-hoc signature, plist lint and `codesign --verify --deep --strict` passed. The app includes its standalone Python/FFmpeg runtime; model weights remain in the regenerable project `ReaderRuntime/Models` folder.

A temporary signed app containing the packaged interpreter successfully imported torch, Kokoro, soundfile, Transformers, tokenizers and PyMuPDF with offline flags; its packaged FFmpeg 7.1 ran. The final release app was copied to a separate temporary folder and passed all 23 import/WebKit plus 42 native reading checks while its SwiftPM development resource bundle was temporarily unavailable. This verifies packaged resources and the optimised native restore path without a development-resource fallback. After the final PDF extraction correction, the app was rebuilt and its packaged backend SHA-256 was checked against the corrected source; all-page real narration passed 27 checks before that rebuild. Developer ID signing and Apple notarisation for distribution were not attempted; local packaging required no credentials.

Command Line Tools here do not supply the XCTest/Swift Testing modules required by conventional `swift test`. The dependency-free `ReaderCoreChecks` executable runs the storage suite instead. This environment uses `--build-system native`; Swift warns that option is deprecated, so a future toolchain may require the default build system or full Xcode.

## Observed manual app checks

- Open Existing Library through the asynchronous native folder picker, including Go to Folder and Open, loaded the fixture library. A crash found in the earlier blocking-panel implementation was fixed by asynchronous AppKit presentation.
- Import sheet → Choose PDFs → Go to Folder → Open completed expected existing-PDF detection. An automation timeout was traced to a stale computer-use app handle; reconnecting by bundle ID allowed completion.
- Batch import displayed article/PDF duplicate Open Existing actions and an HTTP 503 failure with Retry.
- Dark appearance updated native controls and the saved article surface immediately. Command-F focused document search.
- Native PDF search, text selection, highlight creation, passage-note editing and annotation navigation worked through the interface.
- A full app quit/relaunch preserved notes, page 2, 180-degree viewing rotation, zoom and aligned visible highlighting. A page-badge refresh defect found during this check was fixed and covered through an actual `NSHostingView<NativePDFReader>` regression test.
- Narration-panel Play/Pause and playback position worked through the interface. Prepared-script preview exposed an omitted rotated page; Reader’s copied backend was corrected and the final actual narration test now requires every fixture page’s body passage in both extracted text and spoken script. The missing-page defect is fixed rather than accepted as a limitation.

Final light/system appearance and narration-panel playback/export observations are appended after those checks. Automated playback/storage checks do not stand in for an unobserved manual panel action.

## Fixtures and boundaries

The article fixture includes headings, lists, a quotation, repeated sentences in distinct contexts, image caching/failure cases, and unsafe source scripts, event handlers, links and an iframe. The three-page PDF includes selectable text, a pre-rotated second page and coloured graphics. `scripts/fixture-server.py` supplies successful HTML/PDF, redirect, HTTP 503 and unsupported binary routes.

The earlier `pc_reading space` project was inspected read-only: all 104 regular files available locally were zero bytes; nothing was reused or modified.

This release is for one Mac and one active writer. Dropbox cloud-sync completion, multiple-computer editing, iOS/iPadOS, Share extensions, OCR and watched/email capture are not claimed. Source-page JavaScript, authentication and paywall bypass are unsupported; some articles or complex PDF layouts will need a different source or manual review. Large-library performance and exhaustive VoiceOver/physical drag-and-drop coverage were not established by these fixture tests.

## Final manual release checks

Observed in the final signed release on 16 November 2026:

- Opened the corrected temporary narration library through the native folder picker. The prepared-script panel showed the unique passages from pages 1, 2 and 3, including the intrinsically rotated middle page.
- Played and paused the corrected PDF MP3 through the Narration panel. The position advanced and the seek control displayed the generated 1:23 recording.
- Used More → Export MP3 and the native Save panel. The exported `Reader narrated PDF fixture.mp3` was 2,016,620 bytes; its SHA-256 matched the managed original exactly.
- Switched the final app to Light and inspected native controls and PDF colours; then selected Follow system. Earlier manual dark-mode checks covered both app controls and saved article reading surfaces.
- Returned the running app to `/Users/pc/Dropbox/Software/Programs/Reader/ReaderData`. The default library was empty and ready for personal imports; no test fixtures were inserted there. Confirmed the saved library preference is that path and appearance is `system`.

At the end of the initial build verification, the app remained open on the default library. All destructive, failed-import, missing-source and restore checks used separate temporary libraries. Local build and file verification do not establish Dropbox cloud-sync completion.

## First source publication — 16 November 2026

The publication pass changed the default library/runtime paths to follow the source checkout and made the R2M setup default relative to its sibling checkout. Existing selected library paths are preserved.

Fresh checks for these changes:

- Release `Reader` build passed with `swift build --build-system native --configuration release --product Reader`.
- A fresh public clone ran `./scripts/build.sh release` successfully without `ReaderRuntime`, and the resulting app passed `codesign --verify --deep --strict`. This used the installed Swift toolchain, rather than a clean operating system.
- `ReaderCoreChecks` passed all eight storage checks.
- A separately copied ReaderCore checkout compiled and returned its own `ReaderData` path, rather than the original developer path.
- `bash -n scripts/setup-narration.sh` passed. Narration setup still requires a prepared R2M runtime and downloaded model sets; a clean-machine dependency bootstrap was not tested.
- An original demonstration article generated a real 60.225-second MP3 using the local worker and installed models. Play/Pause and elapsed position were observed in the rebuilt release executable, packaged into a separate demo app identity.
- Both publication screenshots use original example text in an isolated library. The personal Reader library was not used for screenshots.

The earlier 108-check verification record above belongs to the initial build; the whole suite was not rerun for this documentation and path-portability pass. The source publication includes no installer, runtime binaries, weights or personal reading data. No application-wide licence was selected.

## 0.2.0 — A4 printing, tags and Original view (17 November 2026)

Fresh automated checks passed: **98 total** — eight ReaderCore checks, 23 import/WebKit checks, 43 native reading checks and 24 printing/tag/Original checks. Import, native reading and the new feature checks were also run successfully through the final signed release app, using isolated temporary libraries. No personal reading content was used as a test fixture.

The native print pipeline produced a multipage A4 article and a three-page fitted A4 PDF. Checks covered every paragraph marker and the final line, all prose words from 120 repeated body/table passages, all 12 table rows, long unbroken code/references, a large figure/caption, selectable text from all three PDF pages (including the rotated page), safe article text margins on every page, and byte-for-byte preservation of both sources. PDF text extraction can interleave table columns, so prose preservation compares word counts rather than assuming linear reading order. Both latest PDFs were rendered with Poppler for visual inspection. Print CSS sets A4/15 mm page margins explicitly; WebKit does not use the native margins alone. A heading directly before a figure stays with that figure in the print copy.

Tag checks covered new tags, case/empty duplicates, reuse of existing names, legacy leading-hash tags, sidebar filtering, library search, complete reopen, and preservation of the latest note and reading position during tag edits. The native interface was also used to add tags with Return, save, filter, clear a filter, reuse an existing tag on a PDF, and remove it again.

Original view checks used a local website with its own layout/scripts and a second page: live rendering, ephemeral storage, absence of the Reader message bridge, rejection of local/script URLs, navigation/back, and preservation of the saved offline copy. Native interface checks confirmed switching to Original and returning from a passage note to the saved Reader view. For a PDF, Reader's highlight disappeared in Original and returned when navigating its saved passage note; the source remained untouched.

Command-P opened the macOS print sheet with A4 (210 × 297 mm), portrait orientation, a complete article preview and the PDF menu. Cancelling returned to the app and re-enabled Print. Physical paper output was not attempted; the configured printer reported offline. Very unusual publisher layouts still warrant checking the preview, and live websites may require a browser/login or reject embedded browsing. A clean machine/macOS 14 installation, exhaustive site compatibility and all physical printers were not tested.

The 0.2.0 release passed plist and strict code-signing checks. The app reopened the existing library and restored the previously selected paper.

## 0.3.0 — Inline narration and playback (18 November 2026)

Fresh automated checks passed: **115 total** — eight ReaderCore checks, 23 import/WebKit checks, 43 native reading checks and **41 real local narration checks**. Debug and release builds passed. The narration suite used the actual local cleanup, Kokoro and MP3 pipeline in an isolated temporary library; the import and native reading suites also passed against the release executable. The 0.2.0 printing suite was not rerun because this update does not change printing.

The expanded narration checks cover persisted Settings defaults, one-click creation without a sheet, reading/navigation/notes during generation, progress scoped to the correct document, captured defaults that do not change mid-job, automatic Play state after commit, seeking before playback, Play/Pause without regeneration, position preservation when switching documents, playback while another document generates, and a fresh controller playing saved audio after library reopen with generation models unavailable. Existing cancellation/failure preservation, complete audio export/restore, source-PDF byte preservation and all-page spoken-text checks also passed.

Manual checks used a separately signed release demo app and original example content:

- An existing article immediately offered Play narration with an elapsed/total seek bar. Seeking before Play did not autoplay; Play/Pause and seeking during playback worked.
- Reader Settings opened with Command-comma. A new PDF narration used the changed speed/reference defaults and displayed inline generation progress. Reading another article and playing its saved recording remained available while that PDF generated. The background Show action returned to the active document.
- Completion changed the PDF action to Play narration. After seeking, a full quit/relaunch preserved the recording, its position and the changed defaults; playback resumed successfully. Both managed audio IDs and SHA-256 hashes were unchanged across the process restart. Defaults were then restored in the demo app only; the completed recording retained its own settings.
- `docs/images/reader-narration.jpg` shows the real inline player with original demonstration text, not personal library content.

The 0.3.0 release passed plist and strict code-signing checks. An existing recording opened with Play narration and a seek bar, retaining its position.

Completed audio remains in the managed item's Narrations folder and its database record, with no expiry. Full-process restart and model-free playback were verified; literal passage of several months was not simulated. Unfinished generation requires Reader to remain open. This update does not change model installation, and a clean-machine setup was not tested.


## 0.3.1 — OpenAI experiment (18 November 2026)

The separate OpenAI experiment used an ignored `.env.local` file for its API key. The key was absent from the app executable and resources.

The experiment passed 49 final mocked native API checks and 18 real API checks. Actual GPT-5.4 mini cleanup and GPT-Realtime-2.1 mini speech produced an original 17.48-second article and a 73.35-second three-page PDF, including its rotated page. MP3 decode, unchanged source bytes, seek/resume, reopen and complete backup/restore passed. The prior local workflow also passed its full regression checks.

The separately signed experiment used its own preferences and an independent library. Native Settings, seeking before Play, Play/Pause and a full process restart were observed with original test content. The saved playback position survived.

## 0.3.2 — Independent cleanup/audio providers (18 November 2026)

The complete `./scripts/verify.sh --narration` run passed **238 checks**: eight core checks, seven Python narration/PDF checks, four comparison-copy tests, 23 imports/WebKit checks, 43 native reading checks, 24 printing/tags/Original checks, 49 mocked native OpenAI checks, 39 provider-matrix checks using real local models with simulated API responses, and 41 retained real local-narration checks.

A separate **33-check live provider matrix** passed with real OpenAI requests and local inference. It generated article recordings through all four cleanup/audio combinations, plus both mixed combinations for the three-page PDF. The checks verified actual engine/provider provenance, intact original prose and selected reference filtering, native MP3 decode/duration, automatic Play state, all rotated/normal PDF page passages and unchanged PDF bytes. No personal reading content was used as an API test fixture.

Provider preferences and per-provider voices persisted across controllers; an existing British local voice survived switching to API and back. A synthetic API key was saved, read and removed through the actual macOS Keychain API under a unique test service, separate from real credentials. The Settings key field never pre-fills a secret; the already approved .env.local remains a supported fallback. There is no database migration: completed audio uses the existing managed attachment/atomic SQLite commit and backup paths.

The signed **Reader 0.3.2 (5)** release built successfully at `build/Reader.app`. Its affected suites passed again through the release bundle: **49 native mocked OpenAI checks and 39 provider-matrix checks**. Plist validation and `codesign --verify --deep --strict` passed. The complete local runtime is bundled for local stages; model weights remain in ReaderRuntime/Models. The existing API key is ignored by Git, mode 0600, and absent from the app executable and project resources.

Observed native release checks:

- Reader Settings exposed independent Text cleanup and Narration audio popups, a provider-specific Voice popup, readiness status, a masked API-key field and Save key. All four combinations could be selected; local/API stages remained independent and the Voice control changed to the selected audio provider.
- A full app quit/relaunch was confirmed by release of the personal library writer lock. Local cleanup/API audio and Marin were still selected after reopening Settings; key availability persisted without showing its value.
- An existing local MP3 and its remembered position remained ready under Play narration while future-generation defaults were set to a mixed route. Narration Details correctly identified the saved audio as local cleanup/local audio, separate from the next-generation defaults. No personal narration was regenerated or sent to OpenAI.

Physical printers, clean-machine local-model setup and all publisher PDF layouts were outside these checks.
