import Foundation
import UniformTypeIdentifiers

/// Which wheel the user summoned while dragging.
nonisolated enum WheelMode: String, CaseIterable, Identifiable, Sendable {
    case convert, tools, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: "Convert formats"
        case .tools: "File tools"
        case .actions: "File actions"
        }
    }
}

/// Broad category of a dropped file; decides which operations are offered.
nonisolated enum FileKind: String, Sendable {
    case image, svg, video, audio, pdf, document, pages, slides, spreadsheet, epub, subtitles, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        if url.hasDirectoryPath, !["rtfd", "pages", "key", "numbers"].contains(url.pathExtension.lowercased()) {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "svg": return .svg
        case "md", "markdown", "txt", "text", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "textclipping": return .document
        case "pages": return .pages
        case "ppt", "pptx", "key", "odp": return .slides
        case "csv", "tsv", "xlsx", "xls", "ods", "numbers": return .spreadsheet
        case "epub": return .epub
        case "srt", "vtt": return .subtitles
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz": return .archive
        case "pdf": return .pdf
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}

nonisolated enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, webp, heic, tiff, avif, bmp, gif, pdf
}

nonisolated enum ImageTool: String, Sendable {
    case compress, resizeHalf, stripMetadata, rotate, flip, grayscale, enhance
    case removeBackground, redactFaces, extractText, cropSquare, addBackground
}

nonisolated enum MediaTool: String, Sendable {
    case compressVideo, extractAudio, mute, videoToGIF, halfSize, rotate, thumbnail, speedUp
    case compressAudio, normalize, merge
}

nonisolated enum PDFTool: String, Sendable {
    case merge, split, compress, rotate, extractImages, ocr
}

nonisolated enum DocFormat: String, CaseIterable, Sendable {
    case docx, rtf, odt, txt, md, html, pdf, epub, pages
}

nonisolated enum SheetFormat: String, CaseIterable, Sendable {
    case csv, tsv, xlsx, json, html, pdf
}

nonisolated enum ArchiveFormat: String, Sendable {
    case zip, tar, tgz
}

nonisolated enum FileAction: String, CaseIterable, Sendable {
    case airdrop, float, copy, move, copyPath, terminal
}

nonisolated enum Action: Hashable, Sendable {
    case imageTo(ImageFormat)
    case imagesToPDF, collage
    case imageTool(ImageTool)
    case mediaTo(String)
    case mediaTool(MediaTool)
    case pdfTo(String)
    case pdfTool(PDFTool)
    case docTo(DocFormat)
    case slidesTo(String)
    case sheetTo(SheetFormat)
    case subtitleTo(String)
    case archive(ArchiveFormat)
    case extract
    case fileAction(FileAction)
}

nonisolated struct Operation: Identifiable, Hashable, Sendable {
    let title: String
    let symbol: String
    let detail: String
    let action: Action
    var id: String { "\(action)" }
}

/// Builds the menu of operations for a given selection and wheel.
enum Catalog {
    static func operations(for urls: [URL], mode: WheelMode) -> [Operation] {
        guard !urls.isEmpty else { return [] }
        if mode == .actions { return fileActions }

        let kinds = Set(urls.map(FileKind.of))
        // Mixed selections only get actions shared by every file, so fall back to the dominant kind
        // when everything is an image-like file, otherwise intersect.
        let kind: FileKind
        if kinds.count == 1 { kind = kinds.first! }
        else if kinds.isSubset(of: [.image, .svg]) { kind = .image }
        else { return mode == .tools ? [archiveOps[0]] : [] }

        let multi = urls.count > 1
        switch (kind, mode) {
        case (.image, .convert), (.svg, .convert):
            return imageFormats(excluding: urls.count == 1 ? urls[0].pathExtension.lowercased() : nil)
        case (.image, .tools), (.svg, .tools):
            var ops = imageTools
            if multi {
                ops.insert(Operation(title: "Collage", symbol: "square.grid.2x2", detail: "Combine images in a grid", action: .collage), at: 0)
                ops.insert(Operation(title: "One PDF", symbol: "doc.richtext", detail: "Combine images into one PDF", action: .imagesToPDF), at: 0)
            }
            return ops
        case (.video, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: $0 == "mp3" ? "music.note" : ($0 == "gif" ? "photo.stack" : "film"),
                          detail: "Convert to \($0.uppercased())", action: .mediaTo($0))
            }
        case (.video, .tools):
            var ops = videoTools
            if multi { ops.insert(Operation(title: "Merge", symbol: "film.stack", detail: "Join videos one after another", action: .mediaTool(.merge)), at: 0) }
            return ops
        case (.audio, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: "waveform", detail: "Convert to \($0.uppercased())", action: .mediaTo($0))
            }
        case (.audio, .tools):
            var ops = audioTools
            if multi { ops.insert(Operation(title: "Merge", symbol: "waveform.badge.plus", detail: "Join tracks one after another", action: .mediaTool(.merge)), at: 0) }
            return ops
        case (.pdf, .convert):
            return [("docx", "doc.text"), ("pages", "doc.richtext"), ("jpg", "photo"), ("png", "photo.fill"),
                    ("epub", "book"), ("txt", "text.alignleft"), ("md", "number"), ("rtf", "doc.plaintext")].map {
                Operation(title: $0.0.uppercased(), symbol: $0.1, detail: "Convert to \($0.0.uppercased())", action: .pdfTo($0.0))
            }
        case (.pdf, .tools):
            var ops = pdfTools
            if multi { ops.insert(Operation(title: "Merge", symbol: "doc.on.doc", detail: "Combine PDFs into one", action: .pdfTool(.merge)), at: 0) }
            return ops
        case (.document, .convert), (.pages, .convert), (.epub, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return DocFormat.allCases
                .filter { $0.rawValue != ext && !(ext == "markdown" && $0 == .md) && !(ext == "htm" && $0 == .html) }
                .filter { $0 != .pages || ConverterEnvironment.pagesAvailable }
                .map { Operation(title: $0 == .md ? "Markdown" : $0.rawValue.uppercased(), symbol: docSymbol($0),
                                 detail: "Convert to \($0.rawValue.uppercased())", action: .docTo($0)) }
        case (.slides, .convert):
            return [("pdf", "doc.richtext"), ("jpg", "photo"), ("png", "photo.fill")].map {
                Operation(title: $0.0.uppercased(), symbol: $0.1, detail: "Export slides as \($0.0.uppercased())", action: .slidesTo($0.0))
            }
        case (.spreadsheet, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return SheetFormat.allCases.filter { $0.rawValue != ext }.map {
                Operation(title: $0.rawValue.uppercased(), symbol: $0 == .pdf ? "doc.richtext" : "tablecells",
                          detail: "Convert to \($0.rawValue.uppercased())", action: .sheetTo($0))
            }
        case (.subtitles, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["srt", "vtt", "txt"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: "captions.bubble", detail: "Convert to \($0.uppercased())", action: .subtitleTo($0))
            }
        case (.archive, .convert):
            return [Operation(title: "Extract", symbol: "archivebox", detail: "Unpack next to the archive", action: .extract)]
                + archiveOps.filter { urls[0].pathExtension.lowercased() != $0.action.archiveExt }
        case (.folder, _), (.other, .tools), (.archive, .tools), (.document, .tools), (.spreadsheet, .tools),
             (.subtitles, .tools), (.epub, .tools), (.slides, .tools), (.pages, .tools):
            return archiveOps
        default:
            return []
        }
    }

    static func imageFormats(excluding ext: String?) -> [Operation] {
        let normalized = ext == "jpeg" ? "jpg" : (ext == "tif" ? "tiff" : ext)
        return ImageFormat.allCases.filter { $0.rawValue != normalized }.map {
            Operation(title: $0.rawValue.uppercased(), symbol: $0 == .pdf ? "doc.richtext" : "photo",
                      detail: "Convert to \($0.rawValue.uppercased())", action: .imageTo($0))
        }
    }

    static let imageTools: [Operation] = [
        .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller file, same look", action: .imageTool(.compress)),
        .init(title: "Resize 50%", symbol: "arrow.down.left.and.arrow.up.right.square", detail: "Half the dimensions", action: .imageTool(.resizeHalf)),
        .init(title: "Strip EXIF", symbol: "location.slash", detail: "Remove location & camera metadata", action: .imageTool(.stripMetadata)),
        .init(title: "Enhance", symbol: "wand.and.stars", detail: "Auto-adjust exposure and color", action: .imageTool(.enhance)),
        .init(title: "Cut out", symbol: "person.crop.rectangle", detail: "Remove the background", action: .imageTool(.removeBackground)),
        .init(title: "Redact", symbol: "eye.slash", detail: "Blur faces and text", action: .imageTool(.redactFaces)),
        .init(title: "Add BG", symbol: "rectangle.inset.filled", detail: "Place on a gradient background", action: .imageTool(.addBackground)),
        .init(title: "Crop 1:1", symbol: "crop", detail: "Center square crop", action: .imageTool(.cropSquare)),
        .init(title: "Rotate", symbol: "rotate.right", detail: "Rotate 90° clockwise", action: .imageTool(.rotate)),
        .init(title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", detail: "Mirror horizontally", action: .imageTool(.flip)),
        .init(title: "B&W", symbol: "circle.lefthalf.filled", detail: "Convert to black & white", action: .imageTool(.grayscale)),
        .init(title: "Text", symbol: "text.viewfinder", detail: "Recognize text into a .txt file", action: .imageTool(.extractText)),
    ]

    static let videoTools: [Operation] = [
        .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "H.264, max 1080p", action: .mediaTool(.compressVideo)),
        .init(title: "Audio", symbol: "music.note", detail: "Extract the audio track", action: .mediaTool(.extractAudio)),
        .init(title: "Mute", symbol: "speaker.slash", detail: "Remove the audio track", action: .mediaTool(.mute)),
        .init(title: "GIF", symbol: "photo.stack", detail: "Animated GIF, 480px", action: .mediaTool(.videoToGIF)),
        .init(title: "Half size", symbol: "arrow.down.left.and.arrow.up.right.square", detail: "Half the resolution", action: .mediaTool(.halfSize)),
        .init(title: "Rotate", symbol: "rotate.right", detail: "Rotate 90° clockwise", action: .mediaTool(.rotate)),
        .init(title: "2× speed", symbol: "forward", detail: "Play twice as fast", action: .mediaTool(.speedUp)),
        .init(title: "Frame", symbol: "photo", detail: "Grab a still frame", action: .mediaTool(.thumbnail)),
    ]

    static let audioTools: [Operation] = [
        .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "MP3 at 128 kbps", action: .mediaTool(.compressAudio)),
        .init(title: "Normalize", symbol: "slider.horizontal.3", detail: "Even out loudness", action: .mediaTool(.normalize)),
        .init(title: "2× speed", symbol: "forward", detail: "Play twice as fast", action: .mediaTool(.speedUp)),
    ]

    static let pdfTools: [Operation] = [
        .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Downsample images", action: .pdfTool(.compress)),
        .init(title: "Split", symbol: "rectangle.split.3x1", detail: "One PDF per page", action: .pdfTool(.split)),
        .init(title: "Rotate", symbol: "rotate.right", detail: "Rotate all pages 90°", action: .pdfTool(.rotate)),
        .init(title: "Images", symbol: "photo.on.rectangle", detail: "Extract every page as PNG", action: .pdfTool(.extractImages)),
        .init(title: "OCR", symbol: "text.viewfinder", detail: "Recognize text from scans", action: .pdfTool(.ocr)),
    ]

    static let archiveOps: [Operation] = [
        .init(title: "ZIP", symbol: "doc.zipper", detail: "Compress to .zip", action: .archive(.zip)),
        .init(title: "TAR", symbol: "archivebox", detail: "Bundle into .tar", action: .archive(.tar)),
        .init(title: "TAR.GZ", symbol: "archivebox.fill", detail: "Compress to .tar.gz", action: .archive(.tgz)),
    ]

    static let fileActions: [Operation] = [
        .init(title: "AirDrop", symbol: "airplayaudio", detail: "Share via AirDrop", action: .fileAction(.airdrop)),
        .init(title: "Float", symbol: "tray", detail: "Keep in a floating shelf", action: .fileAction(.float)),
        .init(title: "Copy", symbol: "doc.on.doc", detail: "Copy files to clipboard", action: .fileAction(.copy)),
        .init(title: "Move", symbol: "folder", detail: "Move to a folder…", action: .fileAction(.move)),
        .init(title: "Copy Path", symbol: "link", detail: "Copy full paths as text", action: .fileAction(.copyPath)),
        .init(title: "Terminal", symbol: "terminal", detail: "Open folder in Terminal", action: .fileAction(.terminal)),
    ]

    static func docSymbol(_ f: DocFormat) -> String {
        switch f {
        case .pdf: "doc.richtext"
        case .txt: "text.alignleft"
        case .md: "number"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .epub: "book"
        default: "doc.text"
        }
    }
}

extension Action {
    var archiveExt: String? {
        if case .archive(let f) = self { return f == .tgz ? "tgz" : f.rawValue }
        return nil
    }
}
