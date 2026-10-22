import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Erases metadata into a "-clean" copy, leaving the original untouched:
/// - every file: macOS extended attributes (download source, quarantine, Finder tags and comments)
/// - images: EXIF, GPS, IPTC, XMP, TIFF, maker notes — losslessly, without re-encoding when possible
/// - PDF: title, author, subject, keywords, creator, XMP
/// - audio/video: all container and stream tags, chapters, creation time, encoder
/// - Office/OpenDocument files: author, last editor, company, manager, dates, custom properties
nonisolated enum MetadataEngine {
    static func strip(_ url: URL, directory: URL?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let out = OutputNamer.url(for: url, ext: ext, suffix: "-clean", directory: directory)
        do {
            switch FileKind.of(url) {
            case .image: try stripImage(url, to: out)
            case .pdf: try stripPDF(url, to: out)
            case .video, .audio: try await stripMedia(url, to: out)
            default:
                try FileManager.default.copyItem(at: url, to: out)
                if ["docx", "xlsx", "pptx", "docm", "xlsm", "pptm"].contains(ext) { try await stripOOXML(out) }
                else if ["odt", "ods", "odp"].contains(ext) { try await stripODF(out) }
            }
            try clearExtendedAttributes(out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: Images

    static func stripImage(_ url: URL, to out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1

        // Lossless path: copy the compressed image data, replacing all metadata with an empty set.
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            // The only tag kept is orientation, so the photo isn't suddenly displayed sideways.
            let metadata = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error), !hasPrivateMetadata(out) {
                return
            }
        }
        // Formats the lossless path can't handle: re-encode the pixels with no metadata at all.
        try? FileManager.default.removeItem(at: out)
        let loaded = try ImageEngine.load(url)
        let format = ImageEngine.format(forExtension: url.pathExtension) ?? .png
        try ImageEngine.write(loaded.image, to: out, format: format, quality: 0.95, keepMetadata: false)
    }

    static func hasPrivateMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        if props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil { return true }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifLensModel] != nil
            || exif[kCGImagePropertyExifBodySerialNumber] != nil { return true }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
            || tiff[kCGImagePropertyTIFFArtist] != nil || tiff[kCGImagePropertyTIFFSoftware] != nil { return true }
        return false
    }

    // MARK: PDF

    static func stripPDF(_ url: URL, to out: URL) throws {
        let doc = try PDFEngine.open(url)
        // Blank values override whatever the writer would carry over; Quartz still stamps its own producer.
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "",
            PDFDocumentAttribute.authorAttribute: "",
            PDFDocumentAttribute.subjectAttribute: "",
            PDFDocumentAttribute.creatorAttribute: "",
            PDFDocumentAttribute.keywordsAttribute: [String](),
        ]
        guard doc.write(to: out) else { throw ConversionError.toolFailed(tr("Couldn't write PDF")) }
    }

    // MARK: Audio / video

    static func stripMedia(_ url: URL, to out: URL) async throws {
        try await Shell.run(try MediaEngine.ffmpeg(), [
            "-y", "-hide_banner", "-loglevel", "error", "-i", url.path,
            "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy",
            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", out.path,
        ])
    }

    // MARK: Office documents

    static func stripOOXML(_ file: URL) async throws {
        let listing = try await Shell.run("/usr/bin/unzip", ["-Z1", file.path])
        let parts = Set(listing.split(separator: "\n").map(String.init))
        var replacements: [String: String] = [:]
        if parts.contains("docProps/core.xml") {
            replacements["docProps/core.xml"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"></cp:coreProperties>
            """
        }
        if parts.contains("docProps/app.xml") {
            let app = try await Shell.run("/usr/bin/unzip", ["-p", file.path, "docProps/app.xml"])
            replacements["docProps/app.xml"] = app
                .replacing(/(?s)<(Company|Manager|HyperlinkBase|Template)>.*?<\/\1>/, with: "")
                .replacing(/<(Company|Manager|HyperlinkBase|Template)\/>/, with: "")
        }
        if parts.contains("docProps/custom.xml") {
            replacements["docProps/custom.xml"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"></Properties>
            """
        }
        try await replaceParts(in: file, replacements)
    }

    static func stripODF(_ file: URL) async throws {
        let listing = try await Shell.run("/usr/bin/unzip", ["-Z1", file.path])
        guard listing.split(separator: "\n").contains("meta.xml") else { return }
        try await replaceParts(in: file, ["meta.xml": """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" office:version="1.3"><office:meta/></office:document-meta>
        """])
    }

    /// Overwrites entries inside a zip-based document in place.
    static func replaceParts(in file: URL, _ parts: [String: String]) async throws {
        guard !parts.isEmpty else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        for (path, content) in parts {
            let dest = temp.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest, atomically: true, encoding: .utf8)
        }
        try await Shell.run("/usr/bin/zip", ["-X", "-q", file.path] + parts.keys.sorted(), currentDirectory: temp)
    }

    // MARK: Extended attributes

    /// `com.apple.provenance` is protected by the system and can't be removed; it holds no personal data.
    static func clearExtendedAttributes(_ url: URL) throws {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buffer = [CChar](repeating: 0, count: size)
        listxattr(url.path, &buffer, size, XATTR_NOFOLLOW)
        let names = buffer.split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }
        for name in names { removexattr(url.path, name, XATTR_NOFOLLOW) }
    }
}
