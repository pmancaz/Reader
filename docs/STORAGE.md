# Storage, backup and recovery

The default is `/Users/pc/Dropbox/Software/Programs/Reader/ReaderData`. A selected existing library may live elsewhere. Reader validates its format marker, refuses a partial library with a missing database, and refuses to open a snapshot as a live library; use Restore for snapshots. Durable paths inside the database are relative to each managed item, so moving the whole library does not break references.

```text
ReaderData/
  Library.json                 format marker and library identity
  Library.sqlite               items, metadata, annotations and reading progress
  .reader.lock                 advisory local writer lock; no user content
  .gitignore                   excludes this live library from Git
  Items/
    <stable-item-ID>/           managed copy of PDF or article plus local assets
      Narrations/<job-ID>/     completed MP3, spoken script and provenance
  Work/                        staged narration jobs; never partial audio in Items
  Backups/
    Reader-<UTC-time>-<ID>/     complete verified snapshots
    Before-migration-.../      snapshots made before a schema migration
  Exports/                     app-created export output
```

The source tree and `build/Reader.app` can be replaced without deleting this folder. Preferences store the selected path and appearance settings; they are not the authority for documents or notes. A configured missing/inaccessible folder must produce a Locate/Retry path. Selecting an existing library is separate from deliberately creating a new one in an empty folder.

## Writes and snapshots

Reader uses SQLite transactions, foreign keys, full synchronous writes and the DELETE journal mode. There is no persistent WAL file to coordinate with Dropbox. A transient SQLite rollback journal may exist during a transaction; never remove it manually while the app is open. Database handles are closed and the local advisory lock released on shutdown. The lock prevents two local Reader writers using the same library. It does not coordinate different computers.

Automatic snapshots are attempted on opening an existing library and after changes when at least 15 minutes have elapsed since the last snapshot. A first change to a new library also produces a snapshot. A clean connection shutdown attempts a fresh snapshot when changes remain since the last backup. Automatic snapshots are complete and can consume disk space; this version does not silently prune old ones. A failed backup is surfaced separately from a successful content save. Before a schema migration, Reader makes a snapshot first.

Each snapshot contains `Library.sqlite`, `Library.json`, all managed `Items` (including completed narration versions), and `Snapshot.json`. SQLite’s supported backup API creates the database copy. The app serialises its writes while assembling the snapshot, computes SHA-256 hashes of its files, verifies those hashes and SQLite integrity, then renames the staging folder into place. A failed staging operation is not presented as a completed backup. Previous backups and exports are excluded to avoid recursively copying backup history.

A complete-library export uses this same snapshot format. Notes/highlights can also be exported as ordinary Markdown including item title, source URL, author where known, added date, tags, quoted passages, PDF page numbers and relative managed-file paths. Keep a separate copy of valuable exports outside Dropbox if you need protection against account loss or a synchronised deletion.

## Restore without overwriting

1. Preserve the current library, including any Dropbox conflict copies. Close any other Reader instance using it.
2. Choose a completed snapshot folder containing `Snapshot.json`, `Library.sqlite`, `Library.json` and `Items`.
3. Restore into a new folder name that does not already exist. Reader verifies the manifest, every file hash and database integrity, then copies into a staging folder and checks that item content is readable. It never restores over an existing destination.
4. Select the restored folder as an existing library. Check several articles/PDFs, annotations and progress before deciding what to do with the old copy.

A restored library starts a new backup/export history; opening it can immediately create its first automatic snapshot. Previous snapshot/export history is not recursively restored. Preserve that history separately if wanted. Restore is a recovery workflow, not an import/merge operation; item identifiers remain stable. Files edited after the selected snapshot are not recovered by it.

## Dropbox limitations

Dropbox is a file synchroniser, not concurrent SQLite replication. Use this version on one Mac with one active writer. Wait for Dropbox to finish syncing after closing Reader before transferring the library to another Mac; local file existence does not prove cloud sync is complete. Do not open the same live database on several computers or mobile devices, even if their lock files appear to match.

Keep the active library available offline in Dropbox. If a file is online-only, downloading or provider availability may fail; Reader must explain that problem rather than invent an empty replacement. A local backup in the same Dropbox account can be synchronised, deleted, corrupted or made unavailable alongside the original. Dropbox alone does not guarantee recovery. Maintain a separate backup destination and periodically restore a snapshot into a separate folder.

Reader detects database filenames containing Dropbox’s `conflicted copy` pattern and refuses to silently choose a winner. Preserve all copies, stop other writers and recover a verified snapshot or explicitly selected database with informed review. Do not rename a conflict file over the main database while Reader is running.

The automatic snapshot mechanism is grounded in [SQLite’s Online Backup API](https://www.sqlite.org/c3ref/backup_finish.html), rather than copying a live database file and hoping its sidecars are complete.
