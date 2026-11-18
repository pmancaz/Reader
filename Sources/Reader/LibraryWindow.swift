import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct LibraryWindow: View {
    @EnvironmentObject var model: AppModel
    @StateObject var bridge = ReaderBridge()
    @StateObject var originalPage = OriginalPageController()
    @FocusState private var searchFocused: Bool
    @FocusState private var documentSearchFocused: Bool
    @ViewState<Bool> private var editMetadata = false
    @ViewState<Bool> private var showAppearance = false
    @ViewState<Bool> private var showTags = false
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        Group {
            if let problem = model.libraryError {
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("Your library needs attention").font(.title2)
                    Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 560)
                    HStack { Button("Locate Library…") { model.locateLibrary() }; Button("Retry") { model.openLibrary(URL(fileURLWithPath: model.libraryPath)) }.keyboardShortcut(.defaultAction); Button("Restore Backup…") { model.restore() } }
                }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    if !model.focusedReading {
                        sidebar.frame(minWidth: 165, idealWidth: 185, maxWidth: 240)
                        library.frame(minWidth: 240, idealWidth: 290, maxWidth: 400)
                    }
                    reading.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    if model.showNotes, model.selectedItem != nil { AnnotationPanel(bridge: bridge).frame(minWidth: 250, idealWidth: 290, maxWidth: 420) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.focusedReading.toggle() } label: { Label(model.focusedReading ? "Show Library" : "Focus Reading", systemImage: "sidebar.left") }.help("Show or hide library (⇧⌘D)")
                Button { model.showImport = true } label: { Label("Import URLs", systemImage: "plus") }.help("Import URLs (⌘N)")
                Button { model.pickPDFs() } label: { Label("Import PDFs", systemImage: "doc.badge.plus") }.help("Import PDFs (⌘O)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let item = model.selectedItem {
                    Button { model.mutate(item) { $0.isFavorite.toggle() } } label: { Label("Favourite", systemImage: item.isFavorite ? "star.fill" : "star") }.help("Favourite")
                    Button { model.mutate(item) { $0.isArchived.toggle() } } label: { Label(item.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }.help(item.isArchived ? "Move out of Archive" : "Archive")
                    Button { editMetadata = true } label: { Label("Edit Details", systemImage: "pencil") }.help("Edit title and tags")
                    if let link = item.originalURL, let url = URL(string: link) { Button { NSWorkspace.shared.open(url) } label: { Label("Open Original", systemImage: "arrow.up.right.square") }.help("Open original in browser") }
                    Button { model.showNotes.toggle() } label: { Label("Notes", systemImage: "sidebar.right") }.help("Notes and highlights (⇧⌘N)")
                }
                Button { showAppearance.toggle() } label: { Label("Appearance", systemImage: "textformat.size") }.help("Reading appearance")
                    .popover(isPresented: $showAppearance) { AppearancePanel().environmentObject(model) }
            }
        }
        .sheet(isPresented: $model.showImport) { ImportPanel() }
        .sheet(isPresented: $model.showNarration) { NarrationPanel(narration: model.narrator).environmentObject(model) }
        .sheet(isPresented: $editMetadata) { if let item = model.selectedItem { MetadataPanel(item: item) } }
        .alert("Reader", isPresented: Binding(get: { model.error != nil || bridge.notice != nil }, set: { if !$0 { model.error = nil; bridge.notice = nil } })) {
            Button("OK") { model.error = nil; bridge.notice = nil }
        } message: { Text(model.error ?? bridge.notice ?? "") }
        .onAppear {
            bridge.onProgress = { id, progress in model.progress(id: id, value: progress) }
            bridge.onAnnotation = { annotation in model.addAnnotation(annotation) }
            bridge.onRequestReader = { model.presentation = .reader }
        }
        .onChange(of: model.presentation) { _, _ in bridge.hasSelection = false }
        .onChange(of: model.selectedID) { _, _ in bridge.hasSelection = false; bridge.pendingNavigation = nil; showTags = false }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "pdf" { Task { @MainActor in model.queue([url]) } }
                }
            }
            return !providers.isEmpty
        }
        .background { VStack {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { documentSearchFocused = true }.keyboardShortcut("f")
        }.hidden() }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
            ForEach(LibrarySection.allCases) { section in
                Button {
                    model.section = section; model.tagFilter = nil
                } label: {
                    HStack(spacing: 10) { Image(systemName: section.icon).frame(width: 18); Text(section.rawValue); Spacer() }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(model.section == section && model.tagFilter == nil ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 8).accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            Group {
                Text("TAGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
                if model.allTags.isEmpty { Text("Use Tags on a document to organise your library.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
                else { ScrollView { VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.allTags, id: \.self) { tag in
                        Button { model.section = .all; model.tagFilter = model.tagFilter == tag ? nil : tag } label: { Label(tag, systemImage: "number").lineLimit(1).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(model.tagFilter == tag ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 10) } }
            }
            Spacer()
            Menu {
                Button("Reveal Library in Finder") { model.reveal() }
                Button("Back Up Now") { model.backup() }
                Button("Export Complete Library…") { model.exportLibrary() }
                Button("Export Notes and Highlights…") { model.exportNotes() }
                Divider()
                Button("Open Existing Library…") { model.locateLibrary() }.disabled(model.importing || model.narrator.isBusy)
                Button("Restore Backup…") { model.restore() }.disabled(model.importing || model.narrator.isBusy)
            } label: { Label("Library", systemImage: "externaldrive").font(.callout) }.menuStyle(.borderlessButton).padding(16)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }
    var library: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search library and notes", text: $model.query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search library and notes") }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)).padding(12)
            HStack { Text(model.tagFilter.map { "#" + $0 } ?? model.section.rawValue).font(.headline); if model.tagFilter != nil { Button { model.tagFilter = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear tag filter").accessibilityLabel("Clear tag filter") }; Spacer(); Text("\(model.visibleItems.count)").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) { Image(systemName: model.query.isEmpty ? "books.vertical" : "magnifyingglass").font(.title).foregroundStyle(.tertiary); Text(model.query.isEmpty ? "No saved items here" : "No matches").font(.headline); Text(model.query.isEmpty ? "Import an article or drop a PDF into Reader." : "Search titles, saved text, tags, and notes.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.visibleItems) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top) { Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(3); Spacer(minLength: 0); if item.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) } }
                            HStack(spacing: 5) { Image(systemName: item.kind == .pdf ? "doc.richtext" : "doc.text"); Text(item.sourceDomain ?? (item.kind == .pdf ? "Local PDF" : "Saved article")).lineLimit(1); Spacer(); if item.status == .finished { Image(systemName: "checkmark") } else if item.status == .unread { Circle().fill(Color.secondary).frame(width: 5, height: 5) } }.font(.caption).foregroundStyle(.secondary)
                            if !item.tags.isEmpty { Text(ReaderTags.normalized(item.tags).map { "#" + $0 }.joined(separator: "  ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }.padding(.vertical, 8).tag(item.id)
                        .contextMenu {
                            Button(item.isFavorite ? "Remove Favourite" : "Favourite") { model.mutate(item) { $0.isFavorite.toggle() } }
                            Button(item.isArchived ? "Unarchive" : "Archive") { model.mutate(item) { $0.isArchived.toggle() } }
                            Button(item.status == .finished ? "Mark Unread" : "Mark Finished") { model.mutate(item) { $0.status = $0.status == .finished ? .unread : .finished } }
                            Divider()
                            Button(item.trashedAt == nil ? "Move to Trash" : "Restore from Trash") { model.mutate(item) { $0.trashedAt = $0.trashedAt == nil ? Date() : nil } }
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                BackgroundNarrationStatus(narration: model.narrator).environmentObject(model)
                Text(model.status).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
    @ViewBuilder var reading: some View {
        if let item = model.selectedItem, let url = try? model.store?.contentURL(for: item) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline).lineLimit(1); Text([item.author, item.sourceDomain, item.addedAt.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Menu {
                        ForEach(ReadingStatus.allCases, id: \.self) { status in Button(status.rawValue.capitalized) { model.mutate(item) { $0.status = status } } }
                        Divider()
                        Button(item.trashedAt == nil ? "Move to Trash" : "Restore from Trash") { model.mutate(item) { $0.trashedAt = $0.trashedAt == nil ? Date() : nil } }
                    } label: { Text(item.trashedAt != nil ? "In Trash" : item.status.rawValue.capitalized).font(.caption) }
                }.padding(.horizontal, 20).padding(.vertical, 14)
                HStack(spacing: 12) {
                    Picker("Document view", selection: $model.presentation) {
                        ForEach(ReadingPresentation.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 166)
                        .help(item.kind == .pdf ? "Original shows the saved PDF without Reader highlights." : "Original loads the live website. Reader is the saved offline copy.")
                    Spacer(minLength: 0)
                    Button { showTags = true } label: { Label("Tags", systemImage: item.tags.isEmpty ? "tag" : "tag.fill") }
                        .help("Add or remove document tags")
                        .popover(isPresented: $showTags) { TagEditorPanel(itemID: item.id).environmentObject(model) }
                    Button { model.printSelected() } label: { Label(model.printer.isBusy ? "Preparing…" : "Print…", systemImage: "printer") }
                        .disabled(model.printer.isBusy).help("Print on A4 (⌘P). Articles use the clean saved copy; PDF pages fit the paper.")
                }.controlSize(.small).padding(.horizontal, 20).padding(.bottom, 12)
                DocumentNarrationPlayer(narration: model.narrator, item: item).environmentObject(model)
                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
                        ForEach(ReaderTags.normalized(item.tags), id: \.self) { tag in
                            Button { model.section = .all; model.tagFilter = tag } label: { Text("#" + tag).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.06), in: Capsule()) }.buttonStyle(.plain).help("Filter library by \(tag)")
                        }
                    } }.padding(.horizontal, 20).padding(.bottom, 10)
                }
                Divider()
                HStack(spacing: 10) {
                    if model.presentation == .reader {
                    Button { bridge.highlight() } label: { Label("Highlight", systemImage: "highlighter") }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!bridge.hasSelection)
                    Button { bridge.highlight(withNote: true) } label: { Label("Note", systemImage: "text.bubble") }.disabled(!bridge.hasSelection)
                    }
                    if item.kind == .pdf {
                        Divider().frame(height: 18)
                        Button { bridge.zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (⌘−)").keyboardShortcut("-")
                        Button { bridge.zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (⌘+)").keyboardShortcut("=")
                        Button { bridge.rotate() } label: { Image(systemName: "rotate.right") }.help("Rotate page for viewing")
                        Menu("\(bridge.pageNumber) / \(bridge.pageCount)") { ForEach(1...max(1, bridge.pageCount), id: \.self) { page in Button("Page \(page)") { bridge.goPage(page) } } }.fixedSize()
                    }
                    Spacer(minLength: 4)
                    TextField("Find in document", text: $bridge.findText).textFieldStyle(.roundedBorder).frame(maxWidth: 170).focused($documentSearchFocused).onSubmit { bridge.find() }.accessibilityLabel("Find in document")
                    Button { bridge.find() } label: { Image(systemName: "magnifyingglass") }.help("Find next")
                }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 9)
                Divider()
                if model.presentation == .original, item.kind == .article { originalSiteBar }
                else if model.presentation == .original { Text("Original PDF · Reader highlights hidden").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8) }
                if model.presentation == .original, item.kind == .article { originalArticle(item) }
                else if !FileManager.default.isReadableFile(atPath: url.path) {
                    VStack(spacing: 16) {
                        Label("The saved file is unavailable", systemImage: "doc.badge.exclamationmark").font(.title3)
                        Text("Make the library available offline in Dropbox, or restore a backup into a new folder.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack { Button("Retry") { try? model.refresh() }; Button("Reveal Library") { model.reveal() }; Button("Restore Backup…") { model.restore() }.disabled(model.importing || model.narrator.isBusy) }
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else if item.kind == .pdf { NativePDFReader(url: url, item: item, annotations: model.presentation == .original ? [] : model.annotations, original: model.presentation == .original, bridge: bridge).id(item.id) }
                else { ArticleReader(url: url, item: item, annotations: model.annotations, fontSize: model.fontSize, lineSpacing: model.lineSpacing, readingWidth: model.readingWidth, dark: colorScheme == .dark, bridge: bridge).id(item.id) }
            }
        } else {
            VStack(spacing: 14) { Image(systemName: "book.closed").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary); Text("A quieter place to read").font(.title2.weight(.medium)); Text("Save an article or PDF, then make it your own.").foregroundStyle(.secondary); Button("Import an article…") { model.showImport = true }.padding(.top, 6) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        }
    }
    func originalArticle(_ item: ReaderItem) -> some View {
        ZStack {
            OriginalArticleReader(item: item, controller: originalPage, bridge: bridge).id(item.id)
            if let error = originalPage.error {
                VStack(spacing: 14) { Image(systemName: "network.slash").font(.title); Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center); HStack { Button("Retry") { originalPage.reload() }; Button("Reader view") { model.presentation = .reader } } }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
    var originalSiteBar: some View {
        HStack(spacing: 10) {
            Button { originalPage.back() } label: { Image(systemName: "chevron.left") }.disabled(!originalPage.canGoBack).help("Back")
            Button { originalPage.forward() } label: { Image(systemName: "chevron.right") }.disabled(!originalPage.canGoForward).help("Forward")
            Button { originalPage.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload original website")
            Text("Live website · " + (originalPage.currentURL?.host ?? model.selectedItem?.sourceDomain ?? "Original")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if originalPage.isLoading { ProgressView().controlSize(.small) }
            if let url = originalPage.currentURL { Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.help("Open website in browser") }
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 9)
    }
}
