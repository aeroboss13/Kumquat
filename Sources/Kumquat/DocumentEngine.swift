import AppKit
import PDFKit
import QuickLookThumbnailing

/// Rich-text documents. Lives on the main actor because AppKit's HTML importer requires it;
/// the conversions are fast enough that this never blocks noticeably.
enum DocumentEngine {
    // MARK: Reading

    static func read(_ url: URL) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "text":
            return plain(try String(contentsOf: url, encoding: .utf8))
        case "md", "markdown":
            return try html(Markdown.toHTML(try String(contentsOf: url, encoding: .utf8)))
        case "epub":
            return try html(try await EPUB.readHTML(url))
        case "pages":
            let temp = try await IWork.export(url, app: "Pages", as: "Microsoft Word", ext: "docx")
            defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
            return try NSAttributedString(url: temp, options: [:], documentAttributes: nil)
        case "pdf":
            return try PDFEngine.attributedText(url)
        default:
            do {
                return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            } catch {
                throw ConversionError.unreadable(url.lastPathComponent)
            }
        }
    }

    static func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
    }

    static func html(_ html: String) throws -> NSAttributedString {
        let styled = "<meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:13pt;color:#000}"
            + "pre,code{font-family:Menlo;font-size:11pt}</style>" + html
        guard let result = NSAttributedString(html: Data(styled.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil) else {
            throw ConversionError.unreadable("HTML")
        }
        return result
    }

    // MARK: Converting

    static func convert(_ url: URL, to format: DocFormat, directory: URL?) async throws -> URL {
        let source = url.pathExtension.lowercased()
        // Pages does the best job with its own files.
        if source == "pages", let native = IWork.pagesFormat(for: format) {
            let out = OutputNamer.url(for: url, ext: format.rawValue, directory: directory)
            try await IWork.export(url, app: "Pages", as: native, to: out)
            return out
        }
        // Plain text and Markdown round-trip losslessly without going through rich text.
        if source == "md" || source == "markdown", format == .html {
            let out = OutputNamer.url(for: url, ext: "html", directory: directory)
            let body = Markdown.toHTML(try String(contentsOf: url, encoding: .utf8))
            try XHTML.page(title: url.deletingPathExtension().lastPathComponent, body: body).write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        if (source == "md" || source == "markdown") && format == .txt || source == "txt" && format == .md {
            let out = OutputNamer.url(for: url, ext: format.rawValue, directory: directory)
            try FileManager.default.copyItem(at: url, to: out)
            return out
        }
        let text = try await read(url)
        return try await write(text, title: url.deletingPathExtension().lastPathComponent, as: format,
                               to: OutputNamer.url(for: url, ext: format.rawValue, directory: directory))
    }

    static func write(_ text: NSAttributedString, title: String, as format: DocFormat, to out: URL) async throws -> URL {
        let range = NSRange(location: 0, length: text.length)
        func data(_ type: NSAttributedString.DocumentType) throws -> Data {
            try text.data(from: range, documentAttributes: [.documentType: type, .title: title])
        }
        switch format {
        case .docx: try data(.officeOpenXML).write(to: out)
        case .rtf: try data(.rtf).write(to: out)
        case .odt: try data(.openDocument).write(to: out)
        case .html: try data(.html).write(to: out)
        case .txt: try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .md: try RichText.markdown(from: text).write(to: out, atomically: true, encoding: .utf8)
        case .pdf: try PDFRenderer.render(text, to: out)
        case .epub: try await EPUB.write(title: title, xhtmlBody: RichText.xhtml(from: text), to: out)
        case .pages:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data(.officeOpenXML).write(to: temp)
            try await IWork.saveAsPages(temp, to: out)
        }
        return out
    }

    // MARK: PDF → anything

    static func convertPDF(_ url: URL, to ext: String, directory: URL?) async throws -> URL {
        switch ext {
        case "jpg", "png":
            return try PDFEngine.renderPages(url, format: ext == "jpg" ? .jpg : .png, dpi: 300, directory: directory)
        case "txt":
            guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
            let out = OutputNamer.url(for: url, ext: "txt", directory: directory)
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        default:
            guard let format = DocFormat(rawValue: ext) else { throw ConversionError.unsupported("PDF → \(ext)") }
            let text = try PDFEngine.attributedText(url)
            return try await write(text, title: url.deletingPathExtension().lastPathComponent, as: format,
                                   to: OutputNamer.url(for: url, ext: ext, directory: directory))
        }
    }

    // MARK: Slides

    static func convertSlides(_ url: URL, to ext: String, directory: URL?) async throws -> URL {
        if let soffice = ConverterEnvironment.tool("soffice") ?? (FileManager.default.fileExists(atPath: "/Applications/LibreOffice.app")
                                                              ? "/Applications/LibreOffice.app/Contents/MacOS/soffice" : nil) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try await Shell.run(soffice, ["--headless", "--convert-to", "pdf", "--outdir", tempDir.path, url.path])
            let pdf = tempDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
            return try await finishSlides(pdf: pdf, original: url, ext: ext, directory: directory)
        }
        if ConverterEnvironment.keynoteAvailable {
            let pdf = try await IWork.export(url, app: "Keynote", as: "PDF", ext: "pdf")
            defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
            return try await finishSlides(pdf: pdf, original: url, ext: ext, directory: directory)
        }
        // Last resort: Quick Look renders the first slide.
        guard ext != "pdf" else {
            throw ConversionError.toolFailed("Exporting slides to PDF needs Keynote (free on the App Store) or LibreOffice.")
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1920, height: 1080), scale: 1, representationTypes: .thumbnail)
        let thumb = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        let out = OutputNamer.url(for: url, ext: ext, directory: directory)
        try ImageEngine.write(thumb.cgImage, to: out, format: ext == "jpg" ? .jpg : .png, quality: 0.9)
        return out
    }

    private static func finishSlides(pdf: URL, original: URL, ext: String, directory: URL?) async throws -> URL {
        if ext == "pdf" {
            let out = OutputNamer.url(for: original, ext: "pdf", directory: directory)
            try FileManager.default.copyItem(at: pdf, to: out)
            return out
        }
        let folder = try PDFEngine.renderPages(pdf, format: ext == "jpg" ? .jpg : .png, dpi: 150, directory: FileManager.default.temporaryDirectory)
        let dest = OutputNamer.uniqueFolder((directory ?? original.deletingLastPathComponent())
            .appendingPathComponent(original.deletingPathExtension().lastPathComponent + " slides"))
        try FileManager.default.moveItem(at: folder, to: dest)
        return dest
    }
}

// MARK: - Rich text walker (attributed string → Markdown / XHTML)

enum RichText {
    struct Run { var text: String; var bold: Bool; var italic: Bool; var link: URL?; var mono: Bool }
    struct Block { var runs: [Run]; var heading: Int; var bullet: Bool }

    static func blocks(from text: NSAttributedString) -> [Block] {
        let ns = text.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Body size = the font size covering the most characters; headings are measured against it.
        var sizeCounts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            sizeCounts[(value as? NSFont)?.pointSize ?? 13, default: 0] += range.length
        }
        let base = sizeCounts.max { $0.value < $1.value }?.key ?? 13

        var blocks: [Block] = []
        ns.enumerateSubstrings(in: full, options: [.byParagraphs]) { _, range, _, _ in
            var runs: [Run] = []
            var maxSize: CGFloat = 0
            var allBold = range.length > 0
            var inList = false
            text.enumerateAttributes(in: range) { attrs, r, _ in
                let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 13)
                let traits = font.fontDescriptor.symbolicTraits
                let bold = traits.contains(.bold) || (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])
                    .flatMap { $0[.weight] as? CGFloat }.map { $0 >= 0.3 } == true
                let raw = ns.substring(with: r)
                if !raw.trimmingCharacters(in: .whitespaces).isEmpty { allBold = allBold && bold }
                maxSize = max(maxSize, font.pointSize)
                if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty { inList = true }
                let link = (attrs[.link] as? URL) ?? (attrs[.link] as? String).flatMap(URL.init(string:))
                runs.append(Run(text: raw, bold: bold, italic: traits.contains(.italic), link: link, mono: traits.contains(.monoSpace)))
            }
            let plain = runs.map(\.text).joined()
            var heading = 0
            if plain.count < 120, !plain.trimmingCharacters(in: .whitespaces).isEmpty {
                if maxSize >= base * 1.6 { heading = 1 }
                else if maxSize >= base * 1.25 { heading = 2 }
                else if maxSize >= base * 1.1 && allBold { heading = 3 }
            }
            var bullet = inList
            if let first = runs.first, let match = first.text.firstMatch(of: /^\s*(?:[•◦▪‣\-–]|\d+[.)])\s+/) {
                bullet = true
                runs[0].text = String(first.text[match.range.upperBound...])
            }
            if heading > 0 { runs = runs.map { var r = $0; r.bold = false; return r } }
            blocks.append(Block(runs: runs, heading: heading, bullet: bullet && heading == 0))
        }
        return blocks
    }

    static func markdown(from text: NSAttributedString) -> String {
        var lines: [String] = []
        for block in blocks(from: text) {
            let body = block.runs.map { run -> String in
                var t = run.text
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return t }
                if run.mono { t = "`\(t)`" }
                if run.bold && run.italic { t = "***\(t)***" } else if run.bold { t = "**\(t)**" } else if run.italic { t = "*\(t)*" }
                if let link = run.link { t = "[\(t)](\(link.absoluteString))" }
                return t
            }.joined()
            if block.heading > 0 { lines.append(String(repeating: "#", count: block.heading) + " " + body) }
            else if block.bullet { lines.append("- " + body) }
            else { lines.append(body) }
        }
        // Blank line between paragraphs, but keep list items tight.
        var result = ""
        for (i, line) in lines.enumerated() {
            result += line
            let nextIsBullet = i + 1 < lines.count && lines[i + 1].hasPrefix("- ")
            result += line.hasPrefix("- ") && nextIsBullet ? "\n" : "\n\n"
        }
        return result.replacing(/\n{3,}/, with: "\n\n")
    }

    static func xhtml(from text: NSAttributedString) -> String {
        var html = ""
        var inList = false
        for block in blocks(from: text) {
            let body = block.runs.map { run -> String in
                var t = XHTML.escape(run.text)
                if run.mono { t = "<code>\(t)</code>" }
                if run.bold { t = "<strong>\(t)</strong>" }
                if run.italic { t = "<em>\(t)</em>" }
                if let link = run.link { t = "<a href=\"\(XHTML.escape(link.absoluteString))\">\(t)</a>" }
                return t
            }.joined()
            if block.bullet != inList { html += block.bullet ? "<ul>\n" : "</ul>\n"; inList = block.bullet }
            if block.heading > 0 { html += "<h\(block.heading)>\(body)</h\(block.heading)>\n" }
            else if block.bullet { html += "<li>\(body)</li>\n" }
            else if body.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            else { html += "<p>\(body)</p>\n" }
        }
        if inList { html += "</ul>\n" }
        return html
    }
}

enum XHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:16px/1.6 -apple-system,Helvetica,sans-serif;max-width:46em;margin:3em auto;padding:0 1em;color:#222}
        pre{background:#f5f5f5;padding:1em;overflow:auto}code{font-family:Menlo,monospace}table{border-collapse:collapse}
        td,th{border:1px solid #ccc;padding:4px 8px}</style></head>
        <body>
        \(body)
        </body></html>
        """
    }
}

// MARK: - Markdown → HTML (CommonMark subset: headings, lists, quotes, code, emphasis, links, images)

enum Markdown {
    static func toHTML(_ source: String) -> String {
        var html = "", paragraph: [String] = [], listTag: String?, inCode = false, code = ""
        func flushParagraph() {
            if !paragraph.isEmpty { html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"; paragraph = [] }
        }
        func closeList() { if let tag = listTag { html += "</\(tag)>\n"; listTag = nil } }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { html += "<pre><code>\(XHTML.escape(code))</code></pre>\n"; code = ""; inCode = false }
                else { flushParagraph(); closeList(); inCode = true }
                continue
            }
            if inCode { code += rawLine + "\n"; continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushParagraph(); closeList()
                let level = m.1.count
                html += "<h\(level)>\(inline(String(m.2)))</h\(level)>\n"
            } else if line.firstMatch(of: /^(-{3,}|\*{3,}|_{3,})$/) != nil {
                flushParagraph(); closeList(); html += "<hr/>\n"
            } else if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flushParagraph()
                if listTag != "ul" { closeList(); html += "<ul>\n"; listTag = "ul" }
                html += "<li>\(inline(String(m.1)))</li>\n"
            } else if let m = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                flushParagraph()
                if listTag != "ol" { closeList(); html += "<ol>\n"; listTag = "ol" }
                html += "<li>\(inline(String(m.1)))</li>\n"
            } else if let m = line.firstMatch(of: /^>\s?(.*)$/) {
                flushParagraph(); closeList()
                html += "<blockquote><p>\(inline(String(m.1)))</p></blockquote>\n"
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        if inCode { html += "<pre><code>\(XHTML.escape(code))</code></pre>\n" }
        flushParagraph(); closeList()
        return html
    }

    static func inline(_ text: String) -> String {
        var s = XHTML.escape(text)
        s = s.replacing(/`([^`]+)`/) { "<code>\($0.1)</code>" }
        s = s.replacing(/!\[([^\]]*)\]\(([^)\s]+)\)/) { "<img alt=\"\($0.1)\" src=\"\($0.2)\"/>" }
        s = s.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        s = s.replacing(/\*\*\*(.+?)\*\*\*/) { "<strong><em>\($0.1)</em></strong>" }
        s = s.replacing(/(\*\*|__)(.+?)\1/) { "<strong>\($0.2)</strong>" }
        s = s.replacing(/\*(\S(?:[^*]*?\S)?)\*/) { "<em>\($0.1)</em>" }
        s = s.replacing(/\b_(\S(?:[^_]*?\S)?)_\b/) { "<em>\($0.1)</em>" }
        s = s.replacing(/~~(.+?)~~/) { "<del>\($0.1)</del>" }
        return s
    }
}

// MARK: - Paginated PDF output via Core Text

nonisolated enum PDFRenderer {
    static func render(_ text: NSAttributedString, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let margin: CGFloat = 56
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw ConversionError.toolFailed("Couldn't create PDF") }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = mediaBox.insetBy(dx: margin, dy: margin)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }
}

// MARK: - EPUB

enum EPUB {
    static func readHTML(_ url: URL) async throws -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, temp.path])
        let container = try String(contentsOf: temp.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = container.firstMatch(of: /full-path="([^"]+)"/)?.1 else { throw ConversionError.unreadable(url.lastPathComponent) }
        let opfURL = temp.appendingPathComponent(String(opfPath))
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        for item in opf.matches(of: /<item\b[^>]*>/) {
            let tag = String(item.0)
            if let id = tag.firstMatch(of: /\bid="([^"]+)"/)?.1, let href = tag.firstMatch(of: /\bhref="([^"]+)"/)?.1 {
                manifest[String(id)] = String(href)
            }
        }
        let spine = opf.matches(of: /<itemref\b[^>]*idref="([^"]+)"/).compactMap { manifest[String($0.1)] }
        var body = ""
        for href in spine {
            let file = opfURL.deletingLastPathComponent().appendingPathComponent(href.removingPercentEncoding ?? href)
            guard let chapter = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let inner = chapter.firstMatch(of: /(?s)<body[^>]*>(.*)<\/body>/)?.1 { body += String(inner) + "\n" }
        }
        // Strip images: their relative paths won't resolve outside the archive.
        return body.replacing(/<img\b[^>]*>/, with: "")
    }

    static func write(title: String, xhtmlBody: String, to url: URL) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        try fm.createDirectory(at: temp.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: temp.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        let t = XHTML.escape(title)
        let files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OEBPS/content.opf": """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(t)</dc:title><dc:language>en</dc:language>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: .now).prefix(19))Z</meta></metadata>
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c1"/></spine></package>
            """,
            "OEBPS/nav.xhtml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head>
            <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(t)</a></li></ol></nav></body></html>
            """,
            "OEBPS/chapter.xhtml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(t)</title></head><body>
            \(xhtmlBody.replacingOccurrences(of: "<hr>", with: "<hr/>"))
            </body></html>
            """,
        ]
        for (path, content) in files { try content.write(to: temp.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        // mimetype must be first and stored uncompressed.
        try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", url.path, "mimetype"], currentDirectory: temp)
        try await Shell.run("/usr/bin/zip", ["-X", "-r", "-9", "-q", url.path, "META-INF", "OEBPS"], currentDirectory: temp)
    }
}

// MARK: - Pages / Keynote via AppleScript

enum IWork {
    static func pagesFormat(for format: DocFormat) -> String? {
        switch format {
        case .docx: "Microsoft Word"
        case .pdf: "PDF"
        case .txt: "unformatted text"
        case .epub: "EPUB"
        default: nil
        }
    }

    static func export(_ url: URL, app: String, as format: String, to out: URL) async throws {
        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set dst to POSIX file (item 2 of argv)
            tell application "\(app)"
                set d to open src
                export d to dst as \(format)
                close d saving no
            end tell
        end run
        """
        try await Shell.run("/usr/bin/osascript", ["-e", script, url.path, out.path])
    }

    /// Exports into a private temp folder and returns the file.
    static func export(_ url: URL, app: String, as format: String, ext: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
        try await export(url, app: app, as: format, to: out)
        return out
    }

    static func saveAsPages(_ docx: URL, to out: URL) async throws {
        guard ConverterEnvironment.pagesAvailable else { throw ConversionError.toolFailed("Pages isn't installed.") }
        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set dst to POSIX file (item 2 of argv)
            tell application "Pages"
                set d to open src
                save d in dst
                close d saving no
            end tell
        end run
        """
        try await Shell.run("/usr/bin/osascript", ["-e", script, docx.path, out.path])
    }
}
