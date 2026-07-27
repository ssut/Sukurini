import CoreGraphics
import Foundation
import ImageIO

enum WebPDisposal: String, CaseIterable {
    case trash
    case delete
    case keep

    static let fallback = WebPDisposal.trash
}

struct ConversionOutcome {
    let source: Screenshot
    let destination: URL
    let outputBytes: Int64
    let image: CGImage
    let elapsed: TimeInterval

    var savedBytes: Int64 { max(0, source.size - outputBytes) }
}

enum ScreenshotConverterError: Error {
    case sourceMissing
    case sourceUnreadable
    case notPNG(type: String)
    case multiFrame(count: Int)
    case decodeFailed
    case outputNotSmaller(input: Int64, output: Int64)
    case verificationFailed(String)
    case destinationExists
    case sourceChanged
    case writeFailed(String)

    var reason: String {
        switch self {
        case .sourceMissing:
            return "source_missing"
        case .sourceUnreadable:
            return "source_unreadable"
        case .notPNG:
            return "not_png"
        case .multiFrame:
            return "multi_frame"
        case .decodeFailed:
            return "decode_failed"
        case .outputNotSmaller:
            return "output_not_smaller"
        case .verificationFailed:
            return "verification_failed"
        case .destinationExists:
            return "destination_exists"
        case .sourceChanged:
            return "source_changed"
        case .writeFailed:
            return "write_failed"
        }
    }
}

enum ScreenshotConverter {
    private static let pngType = "public.png"
    private static let probeKeys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]

    private struct LiveStat: Equatable {
        let size: Int?
        let modified: Date?
    }

    private static func liveStat(_ path: String) -> LiveStat? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return LiveStat(size: attributes[.size] as? Int, modified: attributes[.modificationDate] as? Date)
    }

    static func stage(_ source: Screenshot, effort: Int32) throws -> ConversionOutcome {
        let started = Date()
        let manager = FileManager.default

        guard let values = try? source.url.resourceValues(forKeys: probeKeys),
              let baseline = liveStat(source.path),
              let inputBytes = baseline.size else {
            throw ScreenshotConverterError.sourceMissing
        }

        guard let imageSource = CGImageSourceCreateWithURL(
            source.url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { throw ScreenshotConverterError.sourceUnreadable }

        let type = (CGImageSourceGetType(imageSource) as String?) ?? "unknown"
        guard type == pngType else { throw ScreenshotConverterError.notPNG(type: type) }

        let frames = CGImageSourceGetCount(imageSource)
        guard frames == 1 else { throw ScreenshotConverterError.multiFrame(count: frames) }

        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ScreenshotConverterError.decodeFailed
        }

        let encoded = try WebPEncoder.encodeLossless(image, effort: effort)
        let outputBytes = Int64(encoded.count)
        guard outputBytes < Int64(inputBytes) else {
            throw ScreenshotConverterError.outputNotSmaller(input: Int64(inputBytes), output: outputBytes)
        }

        if let mismatch = verify(encoded, against: image) {
            throw ScreenshotConverterError.verificationFailed(mismatch)
        }

        let destination = ScreenshotFile.convertedURL(for: source.url)
        guard !manager.fileExists(atPath: destination.path) else {
            throw ScreenshotConverterError.destinationExists
        }

        guard let recheck = liveStat(source.path),
              recheck.size == baseline.size,
              recheck.modified == baseline.modified else {
            throw ScreenshotConverterError.sourceChanged
        }

        do {
            try encoded.write(to: destination, options: .atomic)
        } catch {
            throw ScreenshotConverterError.writeFailed(error.localizedDescription)
        }

        applyTimestamps(from: values, to: destination)

        let elapsed = Date().timeIntervalSince(started)
        Log.convert.info("staged path=\(source.path, privacy: .public) input=\(inputBytes, privacy: .public) output=\(outputBytes, privacy: .public) effort=\(effort, privacy: .public) ms=\(Int(elapsed * 1000), privacy: .public)")

        return ConversionOutcome(
            source: source,
            destination: destination,
            outputBytes: outputBytes,
            image: image,
            elapsed: elapsed
        )
    }

    static func dispose(_ url: URL, policy: WebPDisposal) -> Bool {
        switch policy {
        case .keep:
            return true
        case .trash:
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return true
            } catch {
                Log.convert.error("dispose failed reason=trash_failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        case .delete:
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                Log.convert.error("dispose failed reason=remove_failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    static func discard(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            Log.convert.info("discarded staged output path=\(url.path, privacy: .public)")
        } catch {
            Log.convert.error("discard failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private struct ChannelLayout {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int?

        static func resolve(_ image: CGImage) -> ChannelLayout? {
            guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else { return nil }
            guard !image.bitmapInfo.contains(.byteOrder32Little) else { return nil }
            guard !image.bitmapInfo.contains(.floatComponents) else { return nil }
            switch image.alphaInfo {
            case .last:
                return ChannelLayout(red: 0, green: 1, blue: 2, alpha: 3)
            case .noneSkipLast:
                return ChannelLayout(red: 0, green: 1, blue: 2, alpha: nil)
            case .first:
                return ChannelLayout(red: 1, green: 2, blue: 3, alpha: 0)
            case .noneSkipFirst:
                return ChannelLayout(red: 1, green: 2, blue: 3, alpha: nil)
            default:
                return nil
            }
        }
    }

    private static func verify(_ encoded: Data, against original: CGImage) -> String? {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return "decode_back_failed"
        }
        guard decoded.width == original.width, decoded.height == original.height else {
            return "size \(original.width)x\(original.height) vs \(decoded.width)x\(decoded.height)"
        }
        guard let lhsLayout = ChannelLayout.resolve(original),
              let rhsLayout = ChannelLayout.resolve(decoded) else {
            return "layout \(original.alphaInfo.rawValue)/\(decoded.alphaInfo.rawValue) bpp \(original.bitsPerPixel)/\(decoded.bitsPerPixel)"
        }
        guard let lhsData = original.dataProvider?.data, let rhsData = decoded.dataProvider?.data,
              let lhs = CFDataGetBytePtr(lhsData), let rhs = CFDataGetBytePtr(rhsData) else {
            return "pixels_unavailable"
        }

        let width = original.width
        let height = original.height
        let lhsStride = original.bytesPerRow
        let rhsStride = decoded.bytesPerRow
        guard CFDataGetLength(lhsData) >= lhsStride * height, CFDataGetLength(rhsData) >= rhsStride * height else {
            return "pixels_truncated"
        }

        if lhsLayout.alpha == rhsLayout.alpha, lhsLayout.red == rhsLayout.red, lhsStride == rhsStride {
            guard memcmp(lhs, rhs, lhsStride * height) != 0 else { return nil }
        }

        for y in 0..<height {
            let lhsRow = y * lhsStride
            let rhsRow = y * rhsStride
            for x in 0..<width {
                let l = lhsRow + x * 4
                let r = rhsRow + x * 4
                if lhs[l + lhsLayout.red] != rhs[r + rhsLayout.red]
                    || lhs[l + lhsLayout.green] != rhs[r + rhsLayout.green]
                    || lhs[l + lhsLayout.blue] != rhs[r + rhsLayout.blue] {
                    return "rgb at \(x),\(y)"
                }
                let lhsAlpha = lhsLayout.alpha.map { lhs[l + $0] } ?? 255
                let rhsAlpha = rhsLayout.alpha.map { rhs[r + $0] } ?? 255
                if lhsAlpha != rhsAlpha { return "alpha at \(x),\(y)" }
            }
        }
        return nil
    }

    private static func applyTimestamps(from values: URLResourceValues, to destination: URL) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created = values.creationDate { attributes[.creationDate] = created }
        if let modified = values.contentModificationDate { attributes[.modificationDate] = modified }
        guard !attributes.isEmpty else { return }
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path)
        } catch {
            Log.convert.error("timestamp copy failed path=\(destination.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
