import Foundation

public enum ReaderTags {
    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }
    public static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value -> String? in
            var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst(); tag = tag.trimmingCharacters(in: .whitespacesAndNewlines) }
            tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
