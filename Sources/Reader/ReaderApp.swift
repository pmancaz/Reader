import SwiftUI
import AppKit
import ReaderCore

typealias ViewState<Value> = SwiftUI.State<Value>

typealias ReaderItem = ReaderCore.LibraryItem

@main @MainActor
struct ReaderApp: App {
    @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        let state = AppModel()
        _model = StateObject(wrappedValue: state)
        ReaderAppDelegate.model = state
    }
    var body: some Scene {
        WindowGroup(ReaderBuild.name) {
            LibraryWindow().environmentObject(model)
                .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
                .frame(minWidth: 850, minHeight: 560)
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import URLs…") { model.showImport = true }.keyboardShortcut("n")
                Button("Import PDFs…") { model.pickPDFs() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.printSelected() }.keyboardShortcut("p")
                    .disabled(model.selectedItem == nil || model.printer.isBusy)
            }
            CommandGroup(after: .saveItem) {
                Button("Back Up Library Now") { model.backup() }
                Button("Export Complete Library…") { model.exportLibrary() }
                Button("Export Notes and Highlights…") { model.exportNotes() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Open Existing Library…") { model.locateLibrary() }.disabled(model.importing || model.narrator.isBusy)
                Button("Restore Backup into New Folder…") { model.restore() }.disabled(model.importing || model.narrator.isBusy)
                Button("Reveal Library in Finder") { model.reveal() }
            }
            CommandMenu("Reading") {
                Button(model.narrationActionTitle) { model.performNarrationAction() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!model.canPerformNarrationAction)
                Button("Narration Details…") { model.showNarration = true }.disabled(model.selectedItem == nil)
                Button("Toggle Notes Panel") { model.showNotes.toggle() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Distraction-Free Reading") { model.focusedReading.toggle() }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        Settings {
            NarrationSettings(narration: model.narrator)
                .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
        }
    }
}

@MainActor final class ReaderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, !(window is NSPanel), window.title == ReaderBuild.name else { return }
            window.delegate = self
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-imports") {
            Task { let success = await ImportVerification.run(); fflush(stdout); exit(success ? 0 : 1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-narration") {
            Task { let success = await NarrationVerification.run(); fflush(stdout); exit(success ? 0 : 1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-reading") {
            Task { let success = await ReadingVerification.run(); fflush(stdout); exit(success ? 0 : 1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-printing") {
            Task { let success = await PrintingVerification.run(); fflush(stdout); exit(success ? 0 : 1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-openai") || ProcessInfo.processInfo.arguments.contains("--verify-openai-live") {
            let live = ProcessInfo.processInfo.arguments.contains("--verify-openai-live")
            Task { let success = await OpenAIVerification.run(live: live); fflush(stdout); exit(success ? 0 : 1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-providers") || ProcessInfo.processInfo.arguments.contains("--verify-providers-live") {
            let live = ProcessInfo.processInfo.arguments.contains("--verify-providers-live")
            Task { let success = await OpenAIVerification.runProviders(live: live); fflush(stdout); exit(success ? 0 : 1) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { Self.model?.flushPending() ?? true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.model?.flushPending() ?? true else { return .terminateCancel }
        if let narrator = Self.model?.narrator, narrator.isBusy {
            narrator.afterStop = {
                narrator.stopPlayback(); Self.model?.store?.close()
                sender.reply(toApplicationShouldTerminate: true)
            }
            narrator.cancel(); return .terminateLater
        }
        Self.model?.narrator.stopPlayback()
        Self.model?.store?.close(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
