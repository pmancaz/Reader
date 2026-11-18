# Narration

Reader 0.3.2 has independent **Text cleanup** and **Narration audio** choices in **Reader → Settings (Command-comma)**:

| Text cleanup | Narration audio | Processing |
| --- | --- | --- |
| Local models | Local models | R2M/DeBERTa cleanup and Kokoro speech on this Mac; no API request |
| Local models | OpenAI API | Local cleanup, then only the prepared listening text goes to OpenAI for speech |
| OpenAI API | Local models | OpenAI classifies source text for cleanup, then Kokoro voices the prepared script locally |
| OpenAI API | OpenAI API | OpenAI cleanup and speech; no local neural model is loaded |

The audio-provider choice selects its available voices and remembers that provider's previous voice. Cleanup and reference switches remain independent. A running job captures both providers, voice, speed and cleanup choices when it starts. Changing Settings affects future jobs; existing audio continues to play as saved. Use narration options → **Create new narration** to try another combination on an already narrated article. Prior managed recording files remain preserved.

## OpenAI setup

Enter a key in Settings → **OpenAI API key**, then select **Save key**. The field is masked and never prefilled with an existing secret. Keys entered here are stored in macOS Keychain, separate from reading data and backups. A configured `OPENAI_API_KEY` environment variable or the project's ignored `.env.local` also works; a Keychain key takes precedence. Removing a Keychain key does not revoke the OpenAI account key or remove an `.env.local` fallback.

If you already prepared the local runtime below, its FFmpeg encoder works with OpenAI narration too. If you only want OpenAI for both stages, bring an [FFmpeg build](https://ffmpeg.org/download.html) with `libmp3lame` and the `loudnorm` filter. From the Reader checkout, with FFmpeg on your shell path, run:

```sh
mkdir -p ReaderRuntime/bin
cp "$(command -v ffmpeg)" ReaderRuntime/bin/ffmpeg
./scripts/build.sh release
open build/Reader.app
```

Keep any libraries required by your FFmpeg installation on the Mac. Select **OpenAI API** for both stages in Settings and save your key. Use the full runtime setup below when you want to use a local model for either step.

New API narration requires internet access and incurs usage charges. OpenAI cleanup receives extracted document text; OpenAI audio receives the prepared script. Neither receives Reader notes, the library database or the original PDF file. Saved MP3 playback makes no API request and works without a key or model weights.

Cleanup uses [GPT-5.4 mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini) through Responses with strict source-unit decisions, `store:false`, standard processing, no reasoning and low output verbosity. Original wording/order is retained; the model classifies removable boilerplate/reference blocks and short source-matching citation snippets rather than writing a paraphrase. Incomplete/refused/invalid plans are rejected. Ordinary prose cannot be removed through an inline citation edit. Classification can still be imperfect; the original and prepared script remain available, and cleanup/reference choices can be changed for another generation. `store:false` does not establish Zero Data Retention or a regional processing guarantee.

Audio uses [GPT-Realtime-2.1 mini](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini) through a [Realtime WebSocket](https://developers.openai.com/api/docs/guides/realtime-conversations), with independent bounded passages, the selected voice/speed and 24 kHz PCM. A complete response and a matching spoken transcript are required before a passage is accepted. PCM is assembled and encoded into one MP3 locally with FFmpeg. Interrupted/incomplete audio is not published; paid requests are not automatically retried. The current API avoids the retiring older Speech endpoint.

Both API-only and mixed jobs use the same atomic library commit as local narration. Metadata records the actual cleanup/audio providers, engines, settings, request receipts and available token usage. Narration Details shows which providers produced the saved recording. The header's **Next narration** line describes future-generation defaults, rather than relabelling existing audio.

## Local processing

Reader’s narration feature reuses the local R2M text-cleanup and speech pipeline. The app prepares a narration script from the saved document, applies the local DeBERTa cleanup classifier and conservative R2M rules, synthesises speech with Kokoro, and encodes an MP3. Cleanup produces a reversible derivative rather than rewriting the author’s prose. It does not require an online account, API key, subscription or paid service. Source PDFs/articles and their annotations remain independent of generated narration.

## Generate and listen

Select an article or text-layer PDF and use **Create narration** in the document header (or Shift-Command-L). Generation starts immediately using the defaults in **Reader → Settings… (Command-comma)**. A small **Generating narration…** progress bar replaces the button; the document remains available for reading, selection and notes. You can open another paper and return through the background status shown below the library list. One document generates at a time.

When the managed MP3 and database record are committed, the control becomes **Play narration**. The inline player includes Play/Pause, a draggable seek bar, elapsed time and total duration. Seeking before playback loads the saved recording without starting it. Playback position persists with the document, and existing recordings can play while another paper generates. Reopening a narrated article uses its saved audio and does not regenerate it; playback does not require the inference models.

Settings remembers one of five American/British voices, generation speed from 0.6× to 1.5×, cleanup and inclusion of references/citations. A running job captures its defaults when it starts. These settings affect newly generated speech, not the playback rate or existing files. The narration options menu provides MP3 export, Reveal in Finder, **Narration details…** with prepared listening text, and explicit **Create new narration**. Generating another version preserves previous completed files in the library; cancellation/failure preserves the current recording.

Generation runs while Reader is open. Quitting cancels an unfinished job and preserves existing recordings; it does not silently resume an incomplete generation on next launch. Completed narrations have no expiry timer and are kept in the library independently of the regenerable AI runtime and models.

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
