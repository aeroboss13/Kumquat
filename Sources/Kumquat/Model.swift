import Foundation
import UniformTypeIdentifiers

/// Which wheel the user summoned while dragging.
nonisolated enum WheelMode: String, CaseIterable, Identifiable, Sendable {
    case convert, tools, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: tr("Convert formats")
        case .tools: tr("File tools")
        case .actions: tr("File actions")
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
    case compress, resizeHalf, rotate, flip, grayscale, enhance
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
    case stripMetadata
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
        var ops = baseOperations(for: urls, mode: mode)
        // Every file (but not a folder) can have its metadata erased from the tools wheel.
        if mode == .tools, !urls.isEmpty, !urls.contains(where: { FileKind.of($0) == .folder }) {
            ops.insert(stripMetadata, at: 0)
        }
        return ops
    }

    static var stripMetadata: Operation {
        Operation(title: tr("Strip metadata"), symbol: "tag.slash", detail: tr("Erase all metadata"), action: .stripMetadata)
    }

    private static func baseOperations(for urls: [URL], mode: WheelMode) -> [Operation] {
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
                ops.insert(Operation(title: tr("Collage"), symbol: "square.grid.2x2", detail: tr("Combine images in a grid"), action: .collage), at: 0)
                ops.insert(Operation(title: tr("One PDF"), symbol: "doc.richtext", detail: tr("Combine images into one PDF"), action: .imagesToPDF), at: 0)
            }
            return ops
        case (.video, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: $0 == "mp3" ? "music.note" : ($0 == "gif" ? "photo.stack" : "film"),
                          detail: tr("Convert to %@", $0.uppercased()), action: .mediaTo($0))
            }
        case (.video, .tools):
            var ops = videoTools
            if multi { ops.insert(Operation(title: tr("Merge"), symbol: "film.stack", detail: tr("Join videos one after another"), action: .mediaTool(.merge)), at: 0) }
            return ops
        case (.audio, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: "waveform", detail: tr("Convert to %@", $0.uppercased()), action: .mediaTo($0))
            }
        case (.audio, .tools):
            var ops = audioTools
            if multi { ops.insert(Operation(title: tr("Merge"), symbol: "waveform.badge.plus", detail: tr("Join tracks one after another"), action: .mediaTool(.merge)), at: 0) }
            return ops
        case (.pdf, .convert):
            var ops = [("docx", "doc.text"), ("pages", "doc.richtext"), ("jpg", "photo"), ("png", "photo.fill"),
                       ("epub", "book"), ("txt", "text.alignleft"), ("md", "number"), ("rtf", "doc.plaintext")].map {
                Operation(title: $0.0.uppercased(), symbol: $0.1, detail: tr("Convert to %@", $0.0.uppercased()), action: .pdfTo($0.0))
            }
            ops[0] = Operation(title: "DOCX", symbol: "doc.text", detail: tr("Exact copy of every page"), action: .pdfTo("docx"))
            ops[1] = Operation(title: "PAGES", symbol: "doc.richtext", detail: tr("Exact copy of every page"), action: .pdfTo("pages"))
            ops.insert(Operation(title: tr("DOCX text"), symbol: "character.cursor.ibeam", detail: tr("Editable text, layout not kept"),
                                 action: .pdfTo("docx-text")), at: 1)
            if !ConverterEnvironment.pagesAvailable { ops.removeAll { $0.action == .pdfTo("pages") } }
            return ops
        case (.pdf, .tools):
            var ops = pdfTools
            if multi { ops.insert(Operation(title: tr("Merge"), symbol: "doc.on.doc", detail: tr("Combine PDFs into one"), action: .pdfTool(.merge)), at: 0) }
            return ops
        case (.document, .convert), (.pages, .convert), (.epub, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return DocFormat.allCases
                .filter { $0.rawValue != ext && !(ext == "markdown" && $0 == .md) && !(ext == "htm" && $0 == .html) }
                .filter { $0 != .pages || ConverterEnvironment.pagesAvailable }
                .map { Operation(title: $0 == .md ? "Markdown" : $0.rawValue.uppercased(), symbol: docSymbol($0),
                                 detail: tr("Convert to %@", $0.rawValue.uppercased()), action: .docTo($0)) }
        case (.slides, .convert):
            return [("pdf", "doc.richtext"), ("jpg", "photo"), ("png", "photo.fill")].map {
                Operation(title: $0.0.uppercased(), symbol: $0.1, detail: tr("Export slides as %@", $0.0.uppercased()), action: .slidesTo($0.0))
            }
        case (.spreadsheet, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return SheetFormat.allCases.filter { $0.rawValue != ext }.map {
                Operation(title: $0.rawValue.uppercased(), symbol: $0 == .pdf ? "doc.richtext" : "tablecells",
                          detail: tr("Convert to %@", $0.rawValue.uppercased()), action: .sheetTo($0))
            }
        case (.subtitles, .convert):
            let ext = urls[0].pathExtension.lowercased()
            return ["srt", "vtt", "txt"].filter { $0 != ext }.map {
                Operation(title: $0.uppercased(), symbol: "captions.bubble", detail: tr("Convert to %@", $0.uppercased()), action: .subtitleTo($0))
            }
        case (.archive, .convert):
            return [Operation(title: tr("Extract"), symbol: "archivebox", detail: tr("Unpack next to the archive"), action: .extract)]
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
                      detail: tr("Convert to %@", $0.rawValue.uppercased()), action: .imageTo($0))
        }
    }

    static var imageTools: [Operation] { [
        .init(title: tr("Compress"), symbol: "arrow.down.right.and.arrow.up.left", detail: tr("Smaller file, same look"), action: .imageTool(.compress)),
        .init(title: tr("Resize 50%"), symbol: "arrow.down.left.and.arrow.up.right.square", detail: tr("Half the dimensions"), action: .imageTool(.resizeHalf)),
        .init(title: tr("Enhance"), symbol: "wand.and.stars", detail: tr("Auto-adjust exposure and color"), action: .imageTool(.enhance)),
        .init(title: tr("Cut out"), symbol: "person.crop.rectangle", detail: tr("Remove the background"), action: .imageTool(.removeBackground)),
        .init(title: tr("Redact"), symbol: "eye.slash", detail: tr("Blur faces and text"), action: .imageTool(.redactFaces)),
        .init(title: tr("Add BG"), symbol: "rectangle.inset.filled", detail: tr("Place on a gradient background"), action: .imageTool(.addBackground)),
        .init(title: tr("Crop 1:1"), symbol: "crop", detail: tr("Center square crop"), action: .imageTool(.cropSquare)),
        .init(title: tr("Rotate"), symbol: "rotate.right", detail: tr("Rotate 90° clockwise"), action: .imageTool(.rotate)),
        .init(title: tr("Flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", detail: tr("Mirror horizontally"), action: .imageTool(.flip)),
        .init(title: tr("B&W"), symbol: "circle.lefthalf.filled", detail: tr("Convert to black & white"), action: .imageTool(.grayscale)),
        .init(title: tr("Text"), symbol: "text.viewfinder", detail: tr("Recognize text into a .txt file"), action: .imageTool(.extractText)),
    ] }

    static var videoTools: [Operation] { [
        .init(title: tr("Compress"), symbol: "arrow.down.right.and.arrow.up.left", detail: tr("H.264, max 1080p"), action: .mediaTool(.compressVideo)),
        .init(title: tr("Audio"), symbol: "music.note", detail: tr("Extract the audio track"), action: .mediaTool(.extractAudio)),
        .init(title: tr("Mute"), symbol: "speaker.slash", detail: tr("Remove the audio track"), action: .mediaTool(.mute)),
        .init(title: tr("GIF"), symbol: "photo.stack", detail: tr("Animated GIF, 480px"), action: .mediaTool(.videoToGIF)),
        .init(title: tr("Half size"), symbol: "arrow.down.left.and.arrow.up.right.square", detail: tr("Half the resolution"), action: .mediaTool(.halfSize)),
        .init(title: tr("Rotate"), symbol: "rotate.right", detail: tr("Rotate 90° clockwise"), action: .mediaTool(.rotate)),
        .init(title: tr("2× speed"), symbol: "forward", detail: tr("Play twice as fast"), action: .mediaTool(.speedUp)),
        .init(title: tr("Frame"), symbol: "photo", detail: tr("Grab a still frame"), action: .mediaTool(.thumbnail)),
    ] }

    static var audioTools: [Operation] { [
        .init(title: tr("Compress"), symbol: "arrow.down.right.and.arrow.up.left", detail: tr("MP3 at 128 kbps"), action: .mediaTool(.compressAudio)),
        .init(title: tr("Normalize"), symbol: "slider.horizontal.3", detail: tr("Even out loudness"), action: .mediaTool(.normalize)),
        .init(title: tr("2× speed"), symbol: "forward", detail: tr("Play twice as fast"), action: .mediaTool(.speedUp)),
    ] }

    static var pdfTools: [Operation] { [
        .init(title: tr("Compress"), symbol: "arrow.down.right.and.arrow.up.left", detail: tr("Downsample images"), action: .pdfTool(.compress)),
        .init(title: tr("Split"), symbol: "rectangle.split.3x1", detail: tr("One PDF per page"), action: .pdfTool(.split)),
        .init(title: tr("Rotate"), symbol: "rotate.right", detail: tr("Rotate all pages 90°"), action: .pdfTool(.rotate)),
        .init(title: tr("Images"), symbol: "photo.on.rectangle", detail: tr("Extract every page as PNG"), action: .pdfTool(.extractImages)),
        .init(title: tr("OCR"), symbol: "text.viewfinder", detail: tr("Recognize text from scans"), action: .pdfTool(.ocr)),
    ] }

    static var archiveOps: [Operation] { [
        .init(title: "ZIP", symbol: "doc.zipper", detail: tr("Compress to .zip"), action: .archive(.zip)),
        .init(title: "TAR", symbol: "archivebox", detail: tr("Bundle into .tar"), action: .archive(.tar)),
        .init(title: "TAR.GZ", symbol: "archivebox.fill", detail: tr("Compress to .tar.gz"), action: .archive(.tgz)),
    ] }

    static var fileActions: [Operation] { [
        .init(title: tr("AirDrop"), symbol: "airplayaudio", detail: tr("Share via AirDrop"), action: .fileAction(.airdrop)),
        .init(title: tr("Float"), symbol: "tray", detail: tr("Keep in a floating shelf"), action: .fileAction(.float)),
        .init(title: tr("Copy"), symbol: "doc.on.doc", detail: tr("Copy files to clipboard"), action: .fileAction(.copy)),
        .init(title: tr("Move"), symbol: "folder", detail: tr("Move to a folder…"), action: .fileAction(.move)),
        .init(title: tr("Copy Path"), symbol: "link", detail: tr("Copy full paths as text"), action: .fileAction(.copyPath)),
        .init(title: tr("Terminal"), symbol: "terminal", detail: tr("Open folder in Terminal"), action: .fileAction(.terminal)),
    ] }

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
