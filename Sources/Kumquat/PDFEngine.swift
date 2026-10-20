import AppKit
import PDFKit
import Vision

nonisolated enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw ConversionError.toolFailed("\(url.lastPathComponent) is password-protected.") }
        return doc
    }

    static func attributedText(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let text = page.attributedString { result.append(text) }
            if i < doc.pageCount - 1 { result.append(NSAttributedString(string: "\n\n")) }
        }
        if result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Scanned PDF: fall back to OCR.
            let text = try ocrText(doc)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        }
        return result
    }

    static func renderPage(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// One page → a single image file; several pages → a folder of numbered images.
    static func renderPages(_ url: URL, format: ImageFormat, dpi: CGFloat, directory: URL?) throws -> URL {
        let doc = try open(url)
        if doc.pageCount == 1, let page = doc.page(at: 0), let image = renderPage(page, dpi: dpi) {
            let out = OutputNamer.url(for: url, ext: format.rawValue, directory: directory)
            try ImageEngine.write(image, to: out, format: format, quality: 0.9)
            return out
        }
        let folder = OutputNamer.folder(for: url, suffix: " pages", directory: directory)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = renderPage(page, dpi: dpi) else { continue }
            let name = String(format: "%0\(digits)d", i + 1)
            try ImageEngine.write(image, to: folder.appendingPathComponent("\(name).\(format.rawValue)"), format: format, quality: 0.9)
        }
        return folder
    }

    static func merge(_ urls: [URL], directory: URL?) throws -> URL {
        let result = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        let out = OutputNamer.url(named: "Merged", ext: "pdf", in: directory ?? urls[0].deletingLastPathComponent())
        guard result.write(to: out) else { throw ConversionError.toolFailed("Couldn't write PDF") }
        return out
    }

    static func apply(_ tool: PDFTool, to url: URL, directory: URL?) throws -> URL {
        let doc = try open(url)
        switch tool {
        case .compress:
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "-compressed", directory: directory)
            let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            guard ok else { throw ConversionError.toolFailed("Couldn't write PDF") }
            return out
        case .split:
            let folder = OutputNamer.folder(for: url, suffix: " split", directory: directory)
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                let single = PDFDocument()
                if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
                single.write(to: folder.appendingPathComponent(String(format: "Page %0\(digits)d.pdf", i + 1)))
            }
            return folder
        case .rotate:
            for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "-rotated", directory: directory)
            guard doc.write(to: out) else { throw ConversionError.toolFailed("Couldn't write PDF") }
            return out
        case .extractImages:
            return try renderPages(url, format: .png, dpi: 300, directory: directory)
        case .ocr:
            let out = OutputNamer.url(for: url, ext: "txt", directory: directory)
            try ocrText(doc).write(to: out, atomically: true, encoding: .utf8)
            return out
        case .merge:
            return try merge([url], directory: directory)
        }
    }

    static func ocrText(_ doc: PDFDocument) throws -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = renderPage(page, dpi: 200) else { continue }
            pages.append(try ImageEngine.recognizeText(in: image))
        }
        return pages.joined(separator: "\n\n")
    }
}

// MARK: - Spreadsheets

enum SheetEngine {
    typealias Table = [[String]]

    static func convert(_ url: URL, to format: SheetFormat, directory: URL?) async throws -> URL {
        let table = try await read(url)
        let out = OutputNamer.url(for: url, ext: format.rawValue, directory: directory)
        switch format {
        case .csv: try delimited(table, separator: ",").write(to: out, atomically: true, encoding: .utf8)
        case .tsv: try delimited(table, separator: "\t").write(to: out, atomically: true, encoding: .utf8)
        case .json: try json(table).write(to: out)
        case .html: try XHTML.page(title: url.deletingPathExtension().lastPathComponent, body: htmlTable(table)).write(to: out, atomically: true, encoding: .utf8)
        case .xlsx: try await XLSX.write(table, to: out)
        case .pdf:
            let body = "<style>table{border-collapse:collapse;font-size:9pt}td,th{border:1px solid #999;padding:2px 5px}</style>" + htmlTable(table)
            try PDFRenderer.render(try DocumentEngine.html(body), to: out)
        }
        return out
    }

    static func read(_ url: URL) async throws -> Table {
        switch url.pathExtension.lowercased() {
        case "csv": return parseDelimited(try readText(url), separator: ",")
        case "tsv": return parseDelimited(try readText(url), separator: "\t")
        case "xlsx": return try await XLSX.read(url)
        case "ods": return try await ODS.read(url)
        default:
            if let soffice = ConverterEnvironment.tool("soffice") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: dir) }
                try await Shell.run(soffice, ["--headless", "--convert-to", "csv", "--outdir", dir.path, url.path])
                return parseDelimited(try readText(dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")), separator: ",")
            }
            throw ConversionError.toolFailed(".\(url.pathExtension) files need LibreOffice to read. Save as XLSX or CSV first.")
        }
    }

    static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try String(contentsOf: url, encoding: .windowsCP1251)
    }

    static func parseDelimited(_ text: String, separator: Character) -> Table {
        var rows: Table = [], row: [String] = [], field = "", inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" || c == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func delimited(_ table: Table, separator: String) -> String {
        table.map { row in
            row.map { cell in
                cell.contains(separator) || cell.contains("\"") || cell.contains("\n")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    static func json(_ table: Table) throws -> Data {
        guard let header = table.first else { return Data("[]".utf8) }
        let objects = table.dropFirst().map { row in
            Dictionary(header.enumerated().map { ($0.element.isEmpty ? "column\($0.offset + 1)" : $0.element, $0.offset < row.count ? row[$0.offset] : "") },
                       uniquingKeysWith: { a, _ in a })
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }

    static func htmlTable(_ table: Table) -> String {
        var html = "<table>\n"
        for (i, row) in table.enumerated() {
            let tag = i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(XHTML.escape($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return html + "</table>\n"
    }
}

/// Minimal XLSX reader/writer: first worksheet, shared and inline strings, numbers.
enum XLSX {
    static func read(_ url: URL) async throws -> SheetEngine.Table {
        let shared = (try? await Shell.run("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"])) ?? ""
        let workbookRels = (try? await Shell.run("/usr/bin/unzip", ["-p", url.path, "xl/_rels/workbook.xml.rels"])) ?? ""
        let sheetPath = workbookRels.firstMatch(of: /Target="\/?(?:xl\/)?(worksheets\/[^"]+)"/).map { "xl/" + $0.1 } ?? "xl/worksheets/sheet1.xml"
        let sheet = try await Shell.run("/usr/bin/unzip", ["-p", url.path, sheetPath])

        let strings = shared.matches(of: /(?s)<si>(.*?)<\/si>/).map { si in
            String(si.1).matches(of: /(?s)<t[^>]*>(.*?)<\/t>/).map { unescape(String($0.1)) }.joined()
        }
        var table: SheetEngine.Table = []
        for rowMatch in sheet.matches(of: /(?s)<row\b[^>]*>(.*?)<\/row>/) {
            var row: [String] = []
            for cell in String(rowMatch.1).matches(of: /(?s)<c\b([^>]*?)(?:\/>|>(.*?)<\/c>)/) {
                let attrs = String(cell.1)
                let inner = cell.2.map(String.init) ?? ""
                if let ref = attrs.firstMatch(of: /r="([A-Z]+)\d+"/)?.1 {
                    let col = String(ref).unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
                    while row.count < col { row.append("") }
                }
                let type = attrs.firstMatch(of: /t="(\w+)"/)?.1
                let value = inner.firstMatch(of: /(?s)<v>(.*?)<\/v>/).map { unescape(String($0.1)) } ?? ""
                switch type {
                case "s": row.append(Int(value).flatMap { $0 < strings.count ? strings[$0] : nil } ?? "")
                case "inlineStr": row.append(inner.matches(of: /(?s)<t[^>]*>(.*?)<\/t>/).map { unescape(String($0.1)) }.joined())
                default: row.append(value)
                }
            }
            table.append(row)
        }
        return table
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }

    static func write(_ table: SheetEngine.Table, to url: URL) async throws {
        var rows = ""
        for (r, row) in table.enumerated() {
            rows += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(column(c))\(r + 1)"
                if Double(value) != nil, value.firstMatch(of: /^-?\d+(\.\d+)?$/) != nil {
                    rows += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    rows += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XHTML.escape(value))</t></is></c>"
                }
            }
            rows += "</row>"
        }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
            """,
        ]
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        for (path, content) in files {
            let file = temp.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", url.path, "[Content_Types].xml", "_rels", "xl"], currentDirectory: temp)
    }
}

enum ODS {
    static func read(_ url: URL) async throws -> SheetEngine.Table {
        let content = try await Shell.run("/usr/bin/unzip", ["-p", url.path, "content.xml"])
        guard let firstTable = content.firstMatch(of: /(?s)<table:table\b.*?<\/table:table>/)?.0 else { return [] }
        var table: SheetEngine.Table = []
        for rowMatch in String(firstTable).matches(of: /(?s)<table:table-row\b[^>]*>(.*?)<\/table:table-row>/) {
            var row: [String] = []
            for cell in String(rowMatch.1).matches(of: /(?s)<table:table-cell\b([^>]*?)(?:\/>|>(.*?)<\/table:table-cell>)/) {
                let repeatCount = Int(String(cell.1).firstMatch(of: /number-columns-repeated="(\d+)"/)?.1 ?? "1") ?? 1
                let text = (cell.2.map(String.init) ?? "").matches(of: /(?s)<text:p[^>]*>(.*?)<\/text:p>/)
                    .map { XLSX.unescape(String($0.1).replacing(/<[^>]+>/, with: "")) }.joined(separator: "\n")
                row += Array(repeating: text, count: min(repeatCount, 256))
            }
            while row.last == "" { row.removeLast() }
            table.append(row)
        }
        while table.last?.isEmpty == true { table.removeLast() }
        return table
    }
}

// MARK: - Subtitles

nonisolated enum SubtitleEngine {
    struct Cue { var start: String; var end: String; var text: String }

    static func convert(_ url: URL, to ext: String, directory: URL?) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let cues = parse(text)
        let out = OutputNamer.url(for: url, ext: ext, directory: directory)
        let result: String = switch ext {
        case "vtt":
            "WEBVTT\n\n" + cues.map { "\($0.start.replacingOccurrences(of: ",", with: ".")) --> \($0.end.replacingOccurrences(of: ",", with: "."))\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case "srt":
            cues.enumerated().map { i, cue in
                "\(i + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        default:
            cues.map { $0.text.replacing(/<[^>]+>/, with: "") }.joined(separator: "\n") + "\n"
        }
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func parse(_ text: String) -> [Cue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return Cue(start: start, end: end, text: lines[(timingIndex + 1)...].joined(separator: "\n"))
        }
    }

    /// VTT allows "mm:ss.mmm"; SRT needs "hh:mm:ss,mmm".
    static func srtTime(_ t: String) -> String {
        var s = t.replacingOccurrences(of: ".", with: ",")
        if s.filter({ $0 == ":" }).count == 1 { s = "00:" + s }
        return s
    }
}
