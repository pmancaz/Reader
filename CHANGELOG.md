# Changelog

## 0.3.2 — 18 November 2026

- Choose Local models or OpenAI API independently for text cleanup and narration audio; all four combinations are supported in the main Reader app.
- Add a masked API-key field in Settings, with secure macOS Keychain storage and support for the existing project .env.local key.
- Remember a separate voice for each audio provider, preserve existing preferences, and capture each job's providers/settings when generation starts.
- Keep one-click background generation, saved MP3 playback, seeking/resume, notes, printing, tags and Original view. Narration Details identifies the providers that produced saved audio.

## 0.3.1 — OpenAI experiment, 18 November 2026

- Preserve the local version and add a separate Reader OpenAI app/branch with OpenAI text cleanup and speech, its own copied comparison library, and real API verification.

## 0.3.0 — 18 November 2026

- Create narration directly from the document header with one click. Generation uses saved defaults and shows inline progress while reading, selection, notes and document navigation remain available.
- Replace the creation action with Play narration once the completed MP3 is committed to the article. Opening a saved narration plays the existing file; it does not start a new generation.
- Add an inline audio player with Play/Pause, a draggable seek bar, elapsed/total time and a remembered playback position. Existing audio can play while another document generates narration.
- Move voice, speed, cleanup and reference defaults into Reader Settings. All four persist; changes apply to new jobs, including when defaults are changed while another job is running.
- Keep background generation/playback reachable when viewing another paper. Export, prepared text and explicit regeneration remain available under narration options.

## 0.2.0 — 17 November 2026

- Print articles with a clean A4 layout, safe 15 mm margins, wrapped tables/code and automatic pagination. Print existing PDFs fitted to A4 without rewriting the source; use the macOS print panel to save a PDF.
- Switch between the saved Reader copy and the live original website from the document header. Original PDF view hides Reader's highlights while keeping the original page layout.
- Add and remove tags from a dedicated Tags control, reuse existing tags, select header/sidebar tags to filter papers, and clear the current tag filter directly.
- Keep live website browsing separate from local content, annotations and reading position. The embedded Original view includes back, forward, reload and open-in-browser controls.

## 0.1.0 — 16 November 2026

The first version of Reader brings saved articles, PDFs and my notes into one local library.

- Save one or several article/PDF URLs, or import PDF files into a managed offline library.
- Read, highlight and annotate articles and PDFs; keep reading position, tags and library status across restarts.
- Search document text and notes, use favourites and archive, and restore items from Trash.
- Generate local narration with the R2M-derived cleanup and Kokoro pipeline, then play or export a 192 kbps MP3.
- Keep original documents intact, with annotations, listening scripts and audio stored separately.
- Create consistent SQLite-backed library snapshots, restore into a new folder, and export notes as Markdown.
- Include light/dark/system appearance, reading typography controls and keyboard shortcuts.

For this source publication, default library/runtime paths follow the source checkout on a fresh Mac. Existing selected libraries remain unchanged. Runtime binaries, model weights and personal library data are excluded from the repository; optional narration setup reuses a prepared R2M runtime and installed models.
