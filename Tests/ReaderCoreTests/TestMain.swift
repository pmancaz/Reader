import Foundation
import Darwin

/// Dependency-free regression runner, including on Macs with Command Line Tools only.
@main struct CoreCheckMain {
    static func main() {
        let checks: [(String, (LibraryStoreTests) throws -> Void)] = [
            ("persistence, metadata, search, progress and immutable content", { try $0.testLibraryContentAndAnnotationsSurviveReopenAndSearch() }),
            ("complete backup, separate restore and Markdown export", { try $0.testCompleteBackupRestoreAndMarkdownExport() }),
            ("corrupt backups rejected without touching the live library", { try $0.testRestoreRejectsCorruptionWithoutCreatingDestination() }),
            ("single writer, missing library and connection shutdown", { try $0.testSingleWriterMissingLibraryAndClosedStore() }),
            ("unsafe import paths, symlinks and replacement protection", { try $0.testUnsafeImportsAndReplacementAreRejected() }),
            ("annotation document identity and deletion", { try $0.testAnnotationCannotMoveBetweenDocuments() }),
            ("narration versions, playback persistence, legacy decode and complete restore", { try $0.testNarrationPersistenceVersionsAndRestore() }),
            ("backup before migration and Dropbox conflict protection", { try $0.testBeforeMigrationBackupAndDropboxConflictProtection() })
        ]
        var failures = 0
        for (name, body) in checks {
            do { let suite = try LibraryStoreTests(); try body(suite); print("PASS: \(name)") }
            catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
        }
        print("\(checks.count - failures)/\(checks.count) core checks passed; all fixtures used isolated temporary libraries.")
        if failures > 0 { exit(1) }
    }
}
