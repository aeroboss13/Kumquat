import Foundation
import PDFKit

/// Builds a Word document that looks exactly like a PDF: every page is rendered to an image and
/// placed full-bleed on its own Word page of the same size and orientation.
nonisolated enum PageDocx {
    /// Word refuses pages larger than 22 inches; bigger PDF pages are scaled down to fit.
    static let maxSide: CGFloat = 22 * 72
    static let dpi: CGFloat = 200

    static func write(pdf url: URL, to out: URL, progress: ProgressHandler? = nil) async throws {
        let doc = try PDFEngine.open(url)
        guard doc.pageCount > 0 else { throw ConversionError.unreadable(url.lastPathComponent) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let media = temp.appendingPathComponent("word/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("_rels"), withIntermediateDirectories: true)

        var body = ""
        var rels = ""
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = PDFEngine.renderPage(page, dpi: dpi) else { continue }
            let n = i + 1
            try ImageEngine.write(image, to: media.appendingPathComponent("page\(n).jpg"), format: .jpg, quality: 0.88)
            rels += "<Relationship Id=\"rIdP\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\(n).jpg\"/>"

            var size = PDFEngine.displaySize(page)
            let fit = min(1, maxSide / max(size.width, size.height))
            size = CGSize(width: size.width * fit, height: size.height * fit)
            body += pageParagraph(index: n, size: size, isLast: i == doc.pageCount - 1)
            progress?(Double(n) / Double(doc.pageCount))
        }

        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Default Extension="jpg" ContentType="image/jpeg"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
            """,
        ]
        for (path, content) in files {
            try content.write(to: temp.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", out.path, "[Content_Types].xml", "_rels", "word"], currentDirectory: temp)
    }

    /// One Word page: a paragraph holding the page image inline, in its own section sized to the
    /// PDF page with zero margins. Inline pictures render the same in Word, Pages, Google Docs and Quick Look.
    static func pageParagraph(index n: Int, size: CGSize, isLast: Bool) -> String {
        // 2 pt shorter than the page so rounding never pushes the paragraph onto an extra blank page.
        let cx = Int(size.width * 12700), cy = Int((size.height - 2) * 12700)    // points → EMU
        let w = Int(size.width * 20), h = Int(size.height * 20)                   // points → twips
        let orient = w > h ? " w:orient=\"landscape\"" : ""
        let section = """
        <w:sectPr><w:pgSz w:w="\(w)" w:h="\(h)"\(orient)/>\
        <w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>
        """
        let drawing = """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>\
        <wp:docPr id="\(n)" name="Page \(n)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(n)" name="page\(n).jpg"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdP\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
        // The last section's properties belong at the end of <w:body>, the others inside their paragraph.
        let pPr = "<w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>\(isLast ? "" : section)</w:pPr>"
        return "<w:p>\(pPr)<w:r>\(drawing)</w:r></w:p>" + (isLast ? section : "")
    }
}
