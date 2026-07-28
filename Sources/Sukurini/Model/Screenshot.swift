import Foundation

struct Screenshot: Hashable {
    let url: URL
    let created: Date
    let size: Int64

    var path: String { url.path }
    var name: String { url.lastPathComponent }
}

struct StoreChange {
    let inserted: [Screenshot]
    let removedURLs: Set<URL>
    let isFullReload: Bool
    let replacements: [URL: URL]

    init(inserted: [Screenshot], removedURLs: Set<URL>, isFullReload: Bool, replacements: [URL: URL] = [:]) {
        self.inserted = inserted
        self.removedURLs = removedURLs
        self.isFullReload = isFullReload
        self.replacements = replacements
    }

    var isEmpty: Bool { inserted.isEmpty && removedURLs.isEmpty && !isFullReload }

    var arrivals: [Screenshot] {
        guard !replacements.isEmpty else { return inserted }
        let replaced = Set(replacements.values)
        return inserted.filter { !replaced.contains($0.url) }
    }
}

enum ScreenshotFile {
    static let allowedExtensions: Set<String> = ["png", "webp", "heic", "heif", "jpg", "jpeg", "tif", "tiff", "pdf", "gif"]
    static let pngExtension = "png"
    static let convertibleExtension = pngExtension
    static let convertedExtension = "webp"

    static func isEligible(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return allowedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isConvertible(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == convertibleExtension
    }

    static func convertedURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(convertedExtension)
    }
}
