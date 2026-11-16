# Changelog

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
