import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable { case article, pdf }
public enum ReadingStatus: String, Codable, CaseIterable, Sendable { case unread, reading, finished }

public struct ReadingProgress: Codable, Equatable, Sendable {
    public var fraction: Double
    public var pageIndex: Int
    public var zoom: Double
    public var pageRotation: Int
    public var pdfX: Double?
    public var pdfY: Double?
    public var scrollFraction: Double { get { fraction } set { fraction = max(0, min(1, newValue)) } }
    public var updatedAt: Date
    public init(fraction: Double = 0, pageIndex: Int = 0, zoom: Double = 0, pageRotation: Int = 0, pdfX: Double? = nil, pdfY: Double? = nil, updatedAt: Date = Date()) {
        self.fraction = max(0, min(1, fraction)); self.pageIndex = max(0, pageIndex)
        self.zoom = zoom; self.pageRotation = pageRotation; self.pdfX = pdfX; self.pdfY = pdfY; self.updatedAt = updatedAt
    }
}

public struct LibraryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: ItemKind
    public var author: String?
    public var originalURL: String?
    public var sourceDomain: String?
    public var contentPath: String
    public var text: String
    public var tags: [String]
    public var addedAt: Date
    public var status: ReadingStatus
    public var isFavorite: Bool
    public var isArchived: Bool
    public var trashedAt: Date?
    public var progress: ReadingProgress
    public var narration: NarrationRecord?
    public init(id: String = UUID().uuidString, title: String, kind: ItemKind, author: String? = nil,
                originalURL: String? = nil, sourceDomain: String? = nil, contentPath: String, text: String = "",
                tags: [String] = [], addedAt: Date = Date(), status: ReadingStatus = .unread,
                isFavorite: Bool = false, isArchived: Bool = false, trashedAt: Date? = nil,
                progress: ReadingProgress = ReadingProgress(), narration: NarrationRecord? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.author = author; self.originalURL = originalURL
        self.sourceDomain = sourceDomain; self.contentPath = contentPath; self.text = text
        self.tags = tags; self.addedAt = addedAt; self.status = status; self.isFavorite = isFavorite
        self.isArchived = isArchived; self.trashedAt = trashedAt; self.progress = progress; self.narration = narration
    }
}


/// A completed local narration. Paths are relative to Items/<document id>/.
/// Previous narration directories remain intact when a new record is committed.
public struct NarrationRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var relativeAudioPath: String
    public var relativeScriptPath: String
    public var voice: String
    public var speed: Double
    public var createdAt: Date
    public var duration: Double?
    public var playbackPosition: Double
    public init(id: String = UUID().uuidString, relativeAudioPath: String, relativeScriptPath: String,
                voice: String, speed: Double, createdAt: Date = Date(), duration: Double? = nil,
                playbackPosition: Double = 0) {
        self.id = id; self.relativeAudioPath = relativeAudioPath; self.relativeScriptPath = relativeScriptPath
        self.voice = voice; self.speed = speed; self.createdAt = createdAt; self.duration = duration
        self.playbackPosition = max(0, playbackPosition)
    }
    private enum CodingKeys: String, CodingKey {
        case id, relativeAudioPath, relativeScriptPath, voice, speed, createdAt, duration, playbackPosition
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        relativeAudioPath = try values.decode(String.self, forKey: .relativeAudioPath)
        relativeScriptPath = try values.decode(String.self, forKey: .relativeScriptPath)
        voice = try values.decode(String.self, forKey: .voice)
        speed = try values.decode(Double.self, forKey: .speed)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        playbackPosition = try values.decodeIfPresent(Double.self, forKey: .playbackPosition) ?? 0
    }
}

public struct PageRect: Codable, Equatable, Sendable {
    /// PDF page coordinate space, with the unrotated page crop box as its origin.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct PDFAnchorRect: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(pageIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct PDFAnchor: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var rects: [PageRect]
    public var pageRotation: Int
    public init(pageIndex: Int, rects: [PageRect], pageRotation: Int = 0) {
        self.pageIndex = pageIndex; self.rects = rects; self.pageRotation = pageRotation
    }
}

public struct ArticleAnchor: Codable, Equatable, Sendable {
    public var exact: String
    public var prefix: String
    public var suffix: String
    public var start: Int
    public var end: Int
    public init(exact: String, prefix: String = "", suffix: String = "", start: Int = 0, end: Int = 0) {
        self.exact = exact; self.prefix = prefix; self.suffix = suffix; self.start = start; self.end = end
    }
}

public struct ReaderAnnotation: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var itemID: String
    public var quote: String
    public var note: String
    public var color: String
    public var pdfAnchor: PDFAnchor?
    public var pdfRects: [PDFAnchorRect]
    public var articleAnchor: ArticleAnchor?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String = UUID().uuidString, itemID: String, quote: String = "", note: String = "", color: String = "yellow",
                pdfAnchor: PDFAnchor? = nil, pdfRects: [PDFAnchorRect] = [], articleAnchor: ArticleAnchor? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.itemID = itemID; self.quote = quote; self.note = note; self.color = color
        self.pdfAnchor = pdfAnchor; self.pdfRects = pdfRects; self.articleAnchor = articleAnchor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum LibraryError: LocalizedError {
    case missing(String), busy, invalid(String), database(String), io(String)
    public var errorDescription: String? {
        switch self {
        case .missing(let path): return "The Reader library is missing or inaccessible at \(path). Locate the existing library or retry."
        case .busy: return "This library is already open in another Reader window or app instance. Close that instance before opening it here."
        case .invalid(let reason): return "Reader could not use this library: \(reason)"
        case .database(let reason): return "Reader could not save the library: \(reason)"
        case .io(let reason): return reason
        }
    }
}
