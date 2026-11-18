import SwiftUI
import ReaderCore

struct TagEditorPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @ViewState<[String]> private var tags = []
    @ViewState<String> private var entry = ""
    @FocusState private var entryFocused: Bool
    private var suggestions: [String] {
        model.allTags.filter { candidate in
            !tags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
                && (entry.isEmpty || candidate.localizedCaseInsensitiveContains(entry.trimmingCharacters(in: .whitespaces)))
        }
    }
    private func merged() -> [String] {
        let known = model.allTags
        return ReaderTags.normalized((tags + ReaderTags.parse(entry)).map { tag in
            known.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        })
    }
    private func add() { tags = merged(); entry = ""; entryFocused = true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tags").font(.title2.weight(.semibold))
            Text(model.items.first { $0.id == itemID }?.title ?? "Document").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("Add tags, separated by commas", text: $entry).textFieldStyle(.roundedBorder)
                    .focused($entryFocused).onSubmit { add() }.accessibilityLabel("New tags")
                Button("Add") { add() }.disabled(ReaderTags.parse(entry).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tags.isEmpty { Text("No tags yet. Add a subject, project or anything that helps you find this again.").foregroundStyle(.secondary).font(.callout) }
                    else {
                        ForEach(tags, id: \.self) { tag in
                            HStack { Label(tag, systemImage: "tag").textSelection(.enabled); Spacer(); Button { tags.removeAll { $0 == tag } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Remove \(tag)").accessibilityLabel("Remove tag \(tag)") }
                        }
                    }
                    if !suggestions.isEmpty {
                        Divider()
                        Text("EXISTING TAGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { tag in
                            Button { tags = ReaderTags.normalized(tags + [tag]); entry = "" } label: {
                                HStack { Label(tag, systemImage: "plus.circle"); Spacer() }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Add existing tag \(tag)")
                        }
                    }
                }.padding(.vertical, 2)
            }.frame(maxHeight: 300)
            Text("Select a tag in the library sidebar to filter your papers.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { if model.updateTags(itemID: itemID, tags: merged()) { dismiss() } }.keyboardShortcut(.return, modifiers: .command) }
        }.padding(22).frame(width: 370)
            .onAppear { tags = ReaderTags.normalized(model.items.first { $0.id == itemID }?.tags ?? []); entryFocused = true }
    }
}
