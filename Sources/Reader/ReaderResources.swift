import Foundation

/// SwiftPM's native accessor embeds an absolute development path. Packaged apps
/// resolve their copied resource bundle from the standard app resource directory.
enum ReaderResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Reader_Reader.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}
