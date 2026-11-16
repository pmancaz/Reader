# Local narration

Reader’s narration feature reuses the local R2M text-cleanup and speech pipeline. The app prepares a narration script from the saved document, applies the local DeBERTa cleanup classifier and conservative R2M rules, synthesises speech with Kokoro, and encodes an MP3. Cleanup produces a reversible derivative rather than rewriting the author’s prose. It does not require an online account, API key, subscription or paid service. Source PDFs/articles and their annotations remain independent of generated narration.

## Generate and listen

Select an article or text-layer PDF and open **Narration** using the headphones toolbar button or Shift-Command-L. Choose one of five American/British voices and a generation speed from 0.6× to 1.5×. Cleanup and inclusion of references/citations can be selected independently. **Generate MP3** runs locally while you keep reading; **Cancel** preserves existing audio.

A completed narration offers Play/Pause, a seek control, MP3 export and Reveal in Finder. **Prepared listening text** shows the spoken script. Generating another version preserves previous completed files in the library. The speed setting affects newly generated speech; it is not a playback-rate control.

Scanned PDFs need a text layer before narration. Complex PDF layouts can still produce imperfect listening scripts; the saved original and reversible plan remain available for inspection. The optional R2M chat model is neither copied nor used.

## Runtime setup

Prepare Reader’s own offline runtime and model copies once:

```sh
./scripts/setup-narration.sh
```

The initial setup reads the existing prepared R2M app runtime and its installed `speech` and `cleanup` models. It copies them into Reader-owned storage, verifies model sizes/checksums and checks imports without changing R2M. To use another prepared source, set `READER_NARRATION_SOURCE` and `READER_NARRATION_MODELS` for the command. The source R2M installation is no longer a runtime dependency after setup.

```text
ReaderRuntime/                   disposable, regenerable dependencies; ignored by Git
  runtime/bin/python3.11         standalone Python interpreter
  runtime/lib/python3.11/        inference dependencies
  bin/ffmpeg                    local MP3 encoding
  Models/speech/                local speech model weights
  Models/cleanup/               local text-cleanup model weights
  models.json                   verified model manifest
  Licenses/                     copied dependency licences
  THIRD_PARTY_NOTICES.md
  runtime-packages.json
```

Rebuild the app after setup:

```sh
./scripts/build.sh release
```

The packaged app is approximately 1.1 GB and contains its own interpreter, dependencies and FFmpeg under `Reader.app/Contents/Resources/NarrationRuntime/{runtime,bin}` plus licence notices. The approximately 1.1 GB of `Models` weights remain outside the app at this project’s `ReaderRuntime/Models`, avoiding a second copy in every build. Both are regenerable dependencies, separate from personal reading data. Copying the app alone to another Mac does not copy model weights; that Mac needs a supported Reader runtime/model setup and a configured library.

## PDF text coverage

Reader’s copied R2M adapter corrects rotated-page extraction in an unsaved parsing document, then checks that native text spans are represented in the layout output. If the layout pass is incomplete or fails, it preserves the page’s native text instead. Tests cover all four viewing rotations, partial-layout fallback, page order and unchanged original bytes. A page with no text layer produces an OCR notice rather than silently claiming it was narrated.

This uses the coordinate distinction documented by [PyMuPDF’s Page reference](https://pymupdf.readthedocs.io/en/latest/page.html): text coordinates remain unrotated while the page rectangle reflects rotation. The correction applies only to Reader’s copied backend; the original R2M checkout and imported PDFs remain intact.

## Preservation and recovery

Generated scripts, MP3s and job metadata are durable user content in the configured library. Jobs stage their input/output under `Work/Narration-<UUID>` outside `Items` so a backup cannot capture an MP3 while its encoder is still writing it. Successful jobs are committed as a complete managed directory under `Items/<item-ID>/Narrations/<UUID>`, with the current narration record and playback position stored in SQLite. Managed jobs include `audio.mp3`, `script.txt` and their available `extracted.txt`, `plan.json`, `metadata.json`, `request.json`, `result.json` and `input.txt` provenance. Temporary WAV chunks are excluded. Existing useful audio remains available if another generation attempt fails. A failed final commit leaves the work directory available for recovery.

Completed narration files, including previous generated versions, travel with complete-library snapshots and restore with the item. In-progress or failed `Work` jobs are preserved in the active library but are not committed-item snapshots; preserve a failed job directory separately when recovering it. The model weights, interpreter and disposable inference caches are not library backup content. Keep the library backup distinct from these dependencies: regenerating a runtime should never remove a library, prepared narration script or completed recording.

The packaged debug app passed 27 native integration checks using real DeBERTa cleanup, Kokoro synthesis and MP3 encoding for both an article and the three-page PDF fixture. The PDF check requires all three normal/rotated pages in both extracted and spoken text. Checks also include native MP3 decoding, playback progress, stale-item resume, cancellation, missing-source failure preservation, source hashes, provenance, database reopen, and complete audio export/restore. A separate worker run succeeded with network access denied. See [VERIFICATION.md](VERIFICATION.md) for the final release and manual checks.

For repeatable full inference verification in a new temporary library:

```sh
./scripts/verify.sh --narration
```

## Fresh source checkout

Reading itself needs only the Swift/macOS toolchain. Optional narration currently uses the public [R2M installation workflow](https://github.com/pmancaz/R2M#installation) to prepare Python/FFmpeg and install Speech plus Enhanced PDF cleanup first. Keep that checkout beside Reader, or provide `READER_NARRATION_SOURCE` and `READER_NARRATION_MODELS` explicitly. `setup-narration.sh` copies those prepared dependencies; it is not a fresh-runtime downloader. There is no public Reader binary installer in this source publication.

Default library/runtime locations follow the source checkout used to compile Reader, rather than a hard-coded username. Moving the whole library later still uses Open Existing Library; moving model files uses Locate models. A built app continues to use its saved library path.
