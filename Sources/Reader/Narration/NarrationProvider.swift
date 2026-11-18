import Foundation
import Security
import LocalAuthentication
import ReaderCore

enum NarrationProvider: String, CaseIterable, Codable, Sendable {
    case local, openAI
    var name: String { self == .local ? "Local models" : "OpenAI API" }
}

/// Keys entered in Settings stay in the user's macOS Keychain, not preferences,
/// app bundles or reading-library backups. The approved .env.local remains a fallback.
enum ReaderAPIKeychain {
    static let service = "au.pcarroll.Reader.OpenAI"
    static func read(service: String = service) -> String? {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "OPENAI_API_KEY", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, service: String = service) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), !key.contains(where: \.isWhitespace), key.count >= 20 else { throw LibraryError.invalid("Enter a complete OpenAI API key.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "OPENAI_API_KEY"]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LibraryError.io("macOS Keychain could not save the key (\(status)).") }
    }
    static func remove(service: String = service) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "OPENAI_API_KEY"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LibraryError.io("macOS Keychain could not remove the key (\(status)).") }
    }
}

struct LocalNarrationStage: Sendable {
    let runtime: URL
    let models: URL
    let encoder: URL
    let worker: URL

    func run(item: ReaderItem, pdf: URL?, job: URL, options: OpenAINarrationOptions, prepareOnly: Bool,
             progress: @escaping @Sendable (OpenAINarrationProgress) async -> Void) async throws {
        let task = Process(); task.executableURL = runtime.appendingPathComponent("runtime/bin/python3.11")
        var arguments = ["-I", "-B", worker.path, "--job", job.path, "--text", job.appendingPathComponent("input.txt").path,
                         "--title", item.title, "--item-id", item.id, "--models", models.path, "--ffmpeg", encoder.path,
                         "--voice", prepareOnly ? "af_heart" : options.voice, "--speed", String(options.speed), prepareOnly ? "--prepare-only" : "--speak-only"]
        if prepareOnly, let pdf { arguments += ["--pdf", pdf.path] }
        if options.keepReferences { arguments.append("--keep-references") }
        if !options.cleanText { arguments.append("--no-cleanup") }
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"; environment["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = environment
        let log = job.appendingPathComponent(prepareOnly ? "local-cleanup.log" : "local-speech.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        task.standardOutput = handle; task.standardError = handle
        let progressFile = job.appendingPathComponent("progress.json")
        let poll = Task {
            while !Task.isCancelled {
                if let bytes = try? Data(contentsOf: progressFile), let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                    let value = event["fraction"] as? Double ?? 0
                    await progress(.init(phase: prepareOnly ? "Preparing text" : "Generating narration", fraction: prepareOnly ? min(0.27, value) : max(0.28, value), message: event["message"] as? String ?? "Working locally…"))
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.terminationHandler = { process in
                    if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: LibraryError.io("The local \(prepareOnly ? "text cleanup" : "speech") stage could not finish. Check the local runtime/models in Settings. Existing audio has been kept.")) }
                }
                do { try Task.checkCancellation(); try task.run(); if Task.isCancelled { task.terminate() } }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: { if task.isRunning { task.terminate() } }
        try Task.checkCancellation()
    }
}
