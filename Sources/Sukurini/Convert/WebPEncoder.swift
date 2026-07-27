import CoreGraphics
import Foundation
import libwebp

enum WebPEncoderError: Error {
    case dimensionUnsupported(width: Int, height: Int)
    case unsupportedPixelLayout(String)
    case pixelDataUnavailable
    case configFailed
    case pictureFailed
    case importFailed
    case encodeFailed(code: Int32)
    case emptyOutput

    var reason: String {
        switch self {
        case .dimensionUnsupported:
            return "dimension_unsupported"
        case .unsupportedPixelLayout:
            return "unsupported_pixel_layout"
        case .pixelDataUnavailable:
            return "pixel_data_unavailable"
        case .configFailed:
            return "config_failed"
        case .pictureFailed:
            return "picture_failed"
        case .importFailed:
            return "import_failed"
        case .encodeFailed:
            return "encode_failed"
        case .emptyOutput:
            return "empty_output"
        }
    }
}

enum WebPEncoder {
    static let maxDimension = 16383
    static let liveEffort: Int32 = 4
    static let backfillEffort: Int32 = 6

    private enum PixelImport {
        case rgba
        case rgbx
        case rgb
    }

    static func encodeLossless(_ image: CGImage, effort: Int32, threads: Int32 = 0) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else {
            throw WebPEncoderError.dimensionUnsupported(width: width, height: height)
        }

        if let mode = directImportMode(for: image) {
            guard let pixels = image.dataProvider?.data else {
                throw WebPEncoderError.pixelDataUnavailable
            }
            let required = image.bytesPerRow * height
            guard let base = CFDataGetBytePtr(pixels), CFDataGetLength(pixels) >= required else {
                throw WebPEncoderError.pixelDataUnavailable
            }
            let encoded = try withExtendedLifetime(pixels) {
                try encode(
                    width: width,
                    height: height,
                    base: base,
                    stride: Int32(image.bytesPerRow),
                    mode: mode,
                    effort: effort,
                    threads: threads
                )
            }
            return colorManaged(encoded, space: image.colorSpace, width: width, height: height)
        }

        let (buffer, space) = try redrawOpaque(image)
        let encoded = try buffer.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw WebPEncoderError.pixelDataUnavailable
            }
            return try encode(
                width: width,
                height: height,
                base: base,
                stride: Int32(width * 4),
                mode: .rgbx,
                effort: effort,
                threads: threads
            )
        }
        Log.convert.info("encoder redrew unsupported layout w=\(width, privacy: .public) h=\(height, privacy: .public)")
        return colorManaged(encoded, space: space, width: width, height: height)
    }

    private static func directImportMode(for image: CGImage) -> PixelImport? {
        guard image.bitsPerComponent == 8 else { return nil }
        guard !image.bitmapInfo.contains(.byteOrder32Little) else { return nil }
        guard !image.bitmapInfo.contains(.byteOrder16Little) else { return nil }
        guard !image.bitmapInfo.contains(.floatComponents) else { return nil }
        guard image.colorSpace?.model == .rgb else { return nil }

        switch (image.bitsPerPixel, image.alphaInfo) {
        case (32, .last):
            return .rgba
        case (32, .noneSkipLast):
            return .rgbx
        case (24, .none):
            return .rgb
        default:
            return nil
        }
    }

    private static func redrawOpaque(_ image: CGImage) throws -> (Data, CGColorSpace) {
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        guard opaque else {
            throw WebPEncoderError.unsupportedPixelLayout(describe(image))
        }

        let space: CGColorSpace
        if let existing = image.colorSpace, existing.model == .rgb {
            space = existing
        } else {
            space = CGColorSpaceCreateDeviceRGB()
        }

        let width = image.width
        let height = image.height
        let stride = width * 4
        var buffer = Data(count: stride * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: stride,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw WebPEncoderError.pixelDataUnavailable }
        return (buffer, space)
    }

    private static func encode(
        width: Int,
        height: Int,
        base: UnsafePointer<UInt8>,
        stride: Int32,
        mode: PixelImport,
        effort: Int32,
        threads: Int32
    ) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw WebPEncoderError.configFailed }
        guard WebPConfigLosslessPreset(&config, effort) != 0 else { throw WebPEncoderError.configFailed }
        config.exact = 1
        config.thread_level = threads
        guard WebPValidateConfig(&config) != 0 else { throw WebPEncoderError.configFailed }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw WebPEncoderError.pictureFailed }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 1
        picture.width = Int32(width)
        picture.height = Int32(height)

        let imported: Int32
        switch mode {
        case .rgba:
            imported = WebPPictureImportRGBA(&picture, base, stride)
        case .rgbx:
            imported = WebPPictureImportRGBX(&picture, base, stride)
        case .rgb:
            imported = WebPPictureImportRGB(&picture, base, stride)
        }
        guard imported != 0 else { throw WebPEncoderError.importFailed }

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        guard WebPEncode(&config, &picture) != 0 else {
            throw WebPEncoderError.encodeFailed(code: Int32(picture.error_code.rawValue))
        }
        guard let memory = writer.pointee.mem, writer.pointee.size > 0 else {
            throw WebPEncoderError.emptyOutput
        }
        return Data(bytes: memory, count: writer.pointee.size)
    }

    private static func colorManaged(_ encoded: Data, space: CGColorSpace?, width: Int, height: Int) -> Data {
        guard let profile = space?.copyICCData() as Data?, !profile.isEmpty else {
            Log.convert.error("icc profile unavailable w=\(width, privacy: .public) h=\(height, privacy: .public)")
            return encoded
        }
        guard let muxed = attachICC(encoded, profile: profile) else {
            Log.convert.error("icc attach failed bytes=\(profile.count, privacy: .public)")
            return encoded
        }
        return muxed
    }

    private static func attachICC(_ encoded: Data, profile: Data) -> Data? {
        var assembled: Data?
        encoded.withUnsafeBytes { encodedRaw in
            guard let encodedBase = encodedRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            var bitstream = WebPData()
            WebPDataInit(&bitstream)
            bitstream.bytes = encodedBase
            bitstream.size = encoded.count

            guard let mux = WebPMuxCreate(&bitstream, 1) else { return }
            defer { WebPMuxDelete(mux) }

            let applied = profile.withUnsafeBytes { profileRaw -> WebPMuxError in
                guard let profileBase = profileRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return WEBP_MUX_INVALID_ARGUMENT
                }
                var chunk = WebPData()
                WebPDataInit(&chunk)
                chunk.bytes = profileBase
                chunk.size = profile.count
                return WebPMuxSetChunk(mux, "ICCP", &chunk, 1)
            }
            guard applied == WEBP_MUX_OK else { return }

            var output = WebPData()
            WebPDataInit(&output)
            guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK else { return }
            defer { WebPDataClear(&output) }
            guard let bytes = output.bytes, output.size > 0 else { return }
            assembled = Data(bytes: bytes, count: output.size)
        }
        return assembled
    }

    private static func describe(_ image: CGImage) -> String {
        "bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) info=\(image.bitmapInfo.rawValue)"
    }
}
