import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

nonisolated enum ImageEngine {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: Loading

    struct Loaded {
        var image: CGImage
        var properties: [CFString: Any]
        var sourceType: String?
    }

    static func load(_ url: URL) throws -> Loaded {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            return Loaded(image: orient(image, props), properties: props, sourceType: CGImageSourceGetType(source) as String?)
        }
        // SVG, WebP variants ImageIO can't open, etc. — let AppKit rasterize.
        if let nsImage = NSImage(contentsOf: url) {
            var size = nsImage.size
            if size.width < 1024 { let s = 2048 / max(size.width, 1); size = CGSize(width: size.width * s, height: size.height * s) }
            var rect = CGRect(origin: .zero, size: size)
            if let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return Loaded(image: cg, properties: [:], sourceType: nil)
            }
        }
        throw ConversionError.unreadable(url.lastPathComponent)
    }

    /// Bakes EXIF orientation into pixels so outputs look right everywhere.
    static func orient(_ image: CGImage, _ props: [CFString: Any]) -> CGImage {
        guard let raw = props[kCGImagePropertyOrientation] as? UInt32, raw != 1,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }

    // MARK: Writing

    static func utType(for format: ImageFormat) -> UTType {
        switch format {
        case .jpg: .jpeg
        case .png: .png
        case .webp: .webP
        case .heic: .heic
        case .tiff: .tiff
        case .avif: UTType("public.avif") ?? .heic
        case .bmp: .bmp
        case .gif: .gif
        case .pdf: .pdf
        }
    }

    static func canWriteNatively(_ type: UTType) -> Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(type.identifier)
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double,
                      properties: [CFString: Any] = [:], keepMetadata: Bool = true) throws {
        if format == .pdf {
            let doc = PDFDocument()
            let page = PDFPage(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))!
            doc.insert(page, at: 0)
            guard doc.write(to: url) else { throw ConversionError.toolFailed("Couldn't write PDF") }
            return
        }
        let type = utType(for: format)
        var image = image
        if format == .jpg || format == .bmp { image = flatten(image) }

        if !canWriteNatively(type) {
            try writeWithHelper(image, to: url, format: format, quality: quality)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.unsupported("Writing \(format.rawValue.uppercased())")
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = properties[key] { options[key] = value }
            }
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("Couldn't write \(url.lastPathComponent)") }
    }

    /// WebP and (on some systems) AVIF have no ImageIO encoder; hand a PNG to cwebp/avifenc/ffmpeg.
    static func writeWithHelper(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, to: temp, format: .png, quality: 1)
        let q = String(Int(quality * 100))
        let (tool, args): (String?, [String]) = switch format {
        case .webp:
            if let cwebp = ConverterEnvironment.tool("cwebp") { (cwebp, ["-quiet", "-q", q, "-alpha_q", "100", temp.path, "-o", url.path]) }
            else { (ConverterEnvironment.tool("ffmpeg"), ["-y", "-loglevel", "error", "-i", temp.path, "-quality", q, url.path]) }
        case .avif:
            if let avifenc = ConverterEnvironment.tool("avifenc") { (avifenc, ["-q", q, temp.path, url.path]) }
            else { (ConverterEnvironment.tool("ffmpeg"), ["-y", "-loglevel", "error", "-i", temp.path, "-c:v", "libaom-av1", "-still-picture", "1", url.path]) }
        default: (nil, [])
        }
        guard let tool else { throw ConversionError.missingTool(format == .webp ? "webp" : "libavif") }
        let semaphoreResult = runSync(tool, args)
        if let error = semaphoreResult { throw error }
    }

    /// Image helpers are quick; run them synchronously inside the already-background engine.
    static func runSync(_ tool: String, _ args: [String]) -> Error? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return ConversionError.toolFailed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
    }

    static func format(forExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": .jpg
        case "tif", "tiff": .tiff
        case "heif", "heic": .heic
        default: ImageFormat(rawValue: ext.lowercased())
        }
    }

    // MARK: Conversions

    static func convert(_ url: URL, to format: ImageFormat, quality: Double, directory: URL?) throws -> URL {
        let loaded = try load(url)
        let out = OutputNamer.url(for: url, ext: format.rawValue, directory: directory)
        try write(loaded.image, to: out, format: format, quality: quality, properties: loaded.properties)
        return out
    }

    static func combineToPDF(_ urls: [URL], directory: URL?) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            let image = try load(url).image
            if let page = PDFPage(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        let out = OutputNamer.url(named: urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Combined",
                                  ext: "pdf", in: directory ?? urls[0].deletingLastPathComponent())
        guard doc.write(to: out) else { throw ConversionError.toolFailed("Couldn't write PDF") }
        return out
    }

    static func collage(_ urls: [URL], directory: URL?) throws -> URL {
        let images = try urls.map { try load($0).image }
        let columns = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cell: CGFloat = 1000, gap: CGFloat = 24
        let width = Int(CGFloat(columns) * cell + CGFloat(columns + 1) * gap)
        let height = Int(CGFloat(rows) * cell + CGFloat(rows + 1) * gap)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.toolFailed("Couldn't create collage") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            let x = gap + CGFloat(col) * (cell + gap)
            let y = CGFloat(height) - (gap + CGFloat(row + 1) * cell + CGFloat(row) * gap)
            let rect = CGRect(x: x, y: y, width: cell, height: cell)
            // Aspect-fill each tile with rounded corners.
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(cell / iw, cell / ih)
            let draw = CGRect(x: rect.midX - iw * scale / 2, y: rect.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: draw)
            ctx.restoreGState()
        }
        let out = OutputNamer.url(named: "Collage", ext: "jpg", in: directory ?? urls[0].deletingLastPathComponent())
        try write(ctx.makeImage()!, to: out, format: .jpg, quality: 0.9)
        return out
    }

    // MARK: Tools

    static func apply(_ tool: ImageTool, to url: URL, quality: Double, directory: URL?) throws -> URL {
        let loaded = try load(url)
        let image = loaded.image
        let sourceFormat = format(forExtension: url.pathExtension) ?? .png
        let keepFormat: ImageFormat = [.pdf, .gif].contains(sourceFormat) ? .png : sourceFormat

        func save(_ result: CGImage, suffix: String, format: ImageFormat? = nil, quality q: Double? = nil, keepMetadata: Bool = true) throws -> URL {
            let fmt = format ?? keepFormat
            let out = OutputNamer.url(for: url, ext: fmt.rawValue, suffix: suffix, directory: directory)
            try write(result, to: out, format: fmt, quality: q ?? quality, properties: loaded.properties, keepMetadata: keepMetadata)
            return out
        }

        switch tool {
        case .compress:
            // Lossy formats are re-encoded; lossless ones become JPEG (or HEIC when transparency must survive).
            let lossy: Set<ImageFormat> = [.jpg, .heic, .webp, .avif]
            let target: ImageFormat = lossy.contains(sourceFormat) ? sourceFormat : (hasAlpha(image) ? .heic : .jpg)
            let maxSide = 3000.0
            let longest = Double(max(image.width, image.height))
            let resized = longest > maxSide ? scale(image, by: maxSide / longest) : image
            return try save(resized, suffix: "-compressed", format: target, quality: 0.6)
        case .resizeHalf:
            return try save(scale(image, by: 0.5), suffix: "-50%")
        case .stripMetadata:
            return try save(image, suffix: "-clean", keepMetadata: false)
        case .rotate:
            let ci = CIImage(cgImage: image).oriented(.right)
            return try save(render(ci), suffix: "-rotated")
        case .flip:
            let ci = CIImage(cgImage: image).oriented(.upMirrored)
            return try save(render(ci), suffix: "-flipped")
        case .grayscale:
            let filter = CIFilter.photoEffectNoir()
            filter.inputImage = CIImage(cgImage: image)
            return try save(render(filter.outputImage!), suffix: "-bw")
        case .enhance:
            var ci = CIImage(cgImage: image)
            for filter in ci.autoAdjustmentFilters() {
                filter.setValue(ci, forKey: kCIInputImageKey)
                ci = filter.outputImage ?? ci
            }
            return try save(render(ci), suffix: "-enhanced")
        case .cropSquare:
            let side = min(image.width, image.height)
            let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
            return try save(image.cropping(to: rect) ?? image, suffix: "-square")
        case .removeBackground:
            return try save(try removeBackground(image), suffix: "-cutout", format: .png)
        case .redactFaces:
            return try save(try redact(image), suffix: "-redacted")
        case .addBackground:
            return try save(addBackground(image), suffix: "-framed", format: keepFormat == .jpg ? .jpg : .png)
        case .extractText:
            let text = try recognizeText(in: image)
            let out = OutputNamer.url(for: url, ext: "txt", directory: directory)
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
    }

    static func render(_ ci: CIImage) -> CGImage {
        ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
    }

    static func scale(_ image: CGImage, by factor: Double) -> CGImage {
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.scale = Float(factor)
        filter.aspectRatio = 1
        return render(filter.outputImage!)
    }

    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first else { throw ConversionError.toolFailed("No subject found in the image") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        return render(ci)
    }

    static func redact(_ image: CGImage) throws -> CGImage {
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        try VNImageRequestHandler(cgImage: image).perform([faces, text])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var rects = (faces.results ?? []).map { VNImageRectForNormalizedRect($0.boundingBox, Int(w), Int(h)).insetBy(dx: -w * 0.02, dy: -h * 0.03) }
        rects += (text.results ?? []).map { VNImageRectForNormalizedRect($0.boundingBox, Int(w), Int(h)).insetBy(dx: -4, dy: -4) }
        guard !rects.isEmpty else { throw ConversionError.toolFailed("No faces or text found to redact") }

        let original = CIImage(cgImage: image)
        let pixel = CIFilter.pixellate()
        pixel.inputImage = original.clampedToExtent()
        pixel.scale = Float(max(w, h) / 40)
        let pixelated = pixel.outputImage!.cropped(to: original.extent)
        var mask = CIImage(color: .black).cropped(to: original.extent)
        for rect in rects {
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelated
        blend.backgroundImage = original
        blend.maskImage = mask
        return render(blend.outputImage!)
    }

    static func addBackground(_ image: CGImage) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = max(w, h) * 0.08
        let size = CGSize(width: w + pad * 2, height: h + pad * 2)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 1, green: 0.62, blue: 0.27, alpha: 1), CGColor(red: 0.95, green: 0.33, blue: 0.45, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let radius = min(w, h) * 0.04
        ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.15), blur: pad * 0.5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()!
    }

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
