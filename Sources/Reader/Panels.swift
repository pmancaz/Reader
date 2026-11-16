import SwiftUI
import ReaderCore

struct AnnotationPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bridge: ReaderBridge
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Notes & highlights").font(.headline); Spacer(); Button { model.showNotes = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close notes panel") }.padding(16)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.annotations.isEmpty { Text("Select a passage to highlight it or attach a note. You can also add a note for the whole document.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8) }
                        ForEach(model.annotations) { annotation in
                            AnnotationCard(annotation: annotation, bridge: bridge).id(annotation.id)
                        }
                    }.padding(16)
                }.onChange(of: model.lastAnnotationID) { _, id in if let id { withAnimation { scroll.scrollTo(id, anchor: .top) } } }
            }
            Divider()
            Button { if let id = model.selectedID { model.addAnnotation(ReaderAnnotation(itemID: id, note: "")) } } label: { Label("Add document note", systemImage: "plus") }.buttonStyle(.plain).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}
struct AnnotationCard: View {
    @EnvironmentObject var model: AppModel
    let annotation: ReaderAnnotation
    @ObservedObject var bridge: ReaderBridge
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(annotation.quote.isEmpty ? "DOCUMENT NOTE" : "HIGHLIGHT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.deleteAnnotation(annotation) } label: { Image(systemName: "trash").font(.caption) }.buttonStyle(.plain).help("Delete annotation")
            }
            if !annotation.quote.isEmpty {
                Button { bridge.navigate(to: annotation) } label: { Text(annotation.quote).font(.system(size: 13, design: .serif)).lineSpacing(4).foregroundStyle(.primary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain).help("Return to passage")
            }
            TextEditor(text: Binding(get: { model.annotations.first(where: { $0.id == annotation.id })?.note ?? annotation.note }, set: { value in var next = model.annotations.first(where: { $0.id == annotation.id }) ?? annotation; next.note = value; model.save(next) }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).frame(minHeight: 85, maxHeight: 180).padding(6).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1)).focused($focused).accessibilityLabel(annotation.quote.isEmpty ? "Document note" : "Note for highlighted passage")
            Text(annotation.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }.onAppear { if model.lastAnnotationID == annotation.id { focused = true } }
    }
}

struct ImportPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState<String> private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Save something to read").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Paste one or more article or PDF URLs. Reader keeps a local copy for offline reading.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).padding(8).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focused ? 2 : 1)).focused($focused).accessibilityLabel("URLs to import")
            HStack { Button("Choose PDFs…") { model.pickPDFs() }; Spacer(); if model.importing { ProgressView().controlSize(.small); Text("Importing").font(.caption).foregroundStyle(.secondary) }; Button("Import URLs") { model.queueText(text); text = "" }.keyboardShortcut(.return, modifiers: [.command]).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            if !model.jobs.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.jobs) { job in
                            HStack(alignment: .top, spacing: 12) {
                                if !job.complete { ProgressView().controlSize(.small) } else { Image(systemName: job.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(job.failed ? Color.orange : Color.secondary) }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.url.absoluteString).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
                                    Text(job.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if let id = job.existingID { Button("Open") { if let item = model.items.first(where: { $0.id == id }) { model.section = item.trashedAt == nil ? .all : .trash }; model.select(id); dismiss() } }
                                if job.failed, job.url.scheme != "about" { Button("Retry") { model.retry(job.id) } }
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 140, maxHeight: 300)
                if !model.importing { Button("Clear completed imports") { model.jobs.removeAll(where: \.complete) }.buttonStyle(.link).font(.caption) }
            }
        }.padding(24).frame(width: 650).onAppear { focused = true }
    }
}

struct MetadataPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let item: ReaderItem
    @ViewState<String> private var title = ""
    @ViewState<String> private var tags = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Document details").font(.title2)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
            Text("Separate tags with commas.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Type", value: item.kind == .pdf ? "PDF" : "Article")
            LabeledContent("Added", value: item.addedAt.formatted())
            if let author = item.author { LabeledContent("Author", value: author) }
            if let url = item.originalURL { Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { var next = item; next.title = title.trimmingCharacters(in: .whitespacesAndNewlines); next.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(); model.update(next); dismiss() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 470).onAppear { title = item.title; tags = item.tags.joined(separator: ", ") }
    }
}
struct AppearancePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reading appearance").font(.headline)
            Picker("Theme", selection: $model.appearance) { Text("Follow system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            VStack(alignment: .leading) { Text("Font size · \(Int(model.fontSize)) pt"); Slider(value: $model.fontSize, in: 14...30, step: 1) }
            VStack(alignment: .leading) { Text("Line spacing · \(model.lineSpacing, specifier: "%.2f")"); Slider(value: $model.lineSpacing, in: 1.3...2.2, step: 0.05) }
            VStack(alignment: .leading) { Text("Reading width · \(Int(model.readingWidth)) px"); Slider(value: $model.readingWidth, in: 480...1000, step: 20) }
            Text("PDF pages retain their original colours so figures and images stay readable.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 320)
    }
}
