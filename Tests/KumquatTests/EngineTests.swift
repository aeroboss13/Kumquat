import AppKit
import ImageIO
import Foundation
import PDFKit
import Testing
@testable import Kumquat

@MainActor
struct EngineTests {
    let dir: URL
    let engine = Engine(settings: ConversionSettings(outputDirectory: nil, quality: 0.8))

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func makePNG() throws -> URL {
        let url = dir.appendingPathComponent("pic.png")
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 50, y: 50, width: 300, height: 200))
        try ImageEngine.write(ctx.makeImage()!, to: url, format: .png, quality: 1)
        return url
    }

    func run(_ action: Action, _ inputs: [URL]) async throws -> [URL] {
        let out = try await engine.run(action, inputs: inputs) { _ in }
        for url in out { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) missing") }
        return out
    }

    @Test(arguments: ImageFormat.allCases)
    func imageFormats(_ format: ImageFormat) async throws {
        let out = try await run(.imageTo(format), [try makePNG()])
        #expect(out[0].pathExtension == format.rawValue)
        #expect(try out[0].resourceValues(forKeys: [.fileSizeKey]).fileSize! > 100)
    }

    @Test(arguments: [ImageTool.compress, .resizeHalf, .rotate, .flip, .grayscale, .enhance, .cropSquare, .addBackground])
    func imageTools(_ tool: ImageTool) async throws {
        _ = try await run(.imageTool(tool), [try makePNG()])
    }

    @Test func multiImage() async throws {
        let a = try makePNG()
        let b = dir.appendingPathComponent("pic2.png"); try FileManager.default.copyItem(at: a, to: b)
        _ = try await run(.imagesToPDF, [a, b])
        _ = try await run(.collage, [a, b])
    }

    @Test func documents() async throws {
        let md = dir.appendingPathComponent("notes.md")
        try "# Title\n\nSome **bold** and *italic* text with a [link](https://example.com).\n\n- one\n- two\n\n## Section\n\nParagraph.".write(to: md, atomically: true, encoding: .utf8)
        for format in DocFormat.allCases where format != .md && format != .pages {
            let out = try await run(.docTo(format), [md])
            if format == .docx {
                let back = try await run(.docTo(.md), out)
                let text = try String(contentsOf: back[0], encoding: .utf8)
                print("DOCX→MD:\n\(text)")
                #expect(text.contains("**bold**"))
                #expect(text.contains("# Title"))
            }
            if format == .pdf {
                let pdfBack = try await run(.pdfTo("txt"), out)
                #expect(try String(contentsOf: pdfBack[0], encoding: .utf8).contains("Paragraph"))
                _ = try await run(.pdfTo("png"), out)
                _ = try await run(.pdfTo("docx"), out)
                _ = try await run(.pdfTool(.compress), out)
                _ = try await run(.pdfTool(.split), out)
                _ = try await run(.pdfTool(.rotate), out)
                _ = try await run(.pdfTool(.merge), out + out)
            }
            if format == .epub {
                let back = try await run(.docTo(.txt), out)
                #expect(try String(contentsOf: back[0], encoding: .utf8).contains("Paragraph"))
                let check = try await Shell.run("/usr/bin/unzip", ["-l", out[0].path])
                #expect(check.contains("mimetype"))
            }
        }
    }

    @Test func spreadsheets() async throws {
        let csv = dir.appendingPathComponent("data.csv")
        try "name,qty,note\nApple,3,\"red, sweet\"\nPear,10,\"say \"\"hi\"\"\"\n".write(to: csv, atomically: true, encoding: .utf8)
        for format in SheetFormat.allCases where format != .csv { _ = try await run(.sheetTo(format), [csv]) }
        let xlsx = dir.appendingPathComponent("data.xlsx")
        let back = try await run(.sheetTo(.csv), [xlsx])
        let text = try String(contentsOf: back[0], encoding: .utf8)
        #expect(text == "name,qty,note\nApple,3,\"red, sweet\"\nPear,10,\"say \"\"hi\"\"\"\n")
    }

    @Test func subtitles() async throws {
        let srt = dir.appendingPathComponent("movie.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try await run(.subtitleTo("vtt"), [srt])
        #expect(try String(contentsOf: vtt[0], encoding: .utf8).hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello"))
        let back = try await run(.subtitleTo("srt"), vtt)
        #expect(try String(contentsOf: back[0], encoding: .utf8).contains("1\n00:00:01,000 --> 00:00:02,500\nHello"))
    }

    @Test func archives() async throws {
        let png = try makePNG()
        for format in [ArchiveFormat.zip, .tar, .tgz] {
            let archive = try await run(.archive(format), [png])
            let extracted = try await run(.extract, archive)
            #expect(FileManager.default.fileExists(atPath: extracted[0].appendingPathComponent("pic.png").path), "\(format)")
        }
    }

    @Test func media() async throws {
        let wav = dir.appendingPathComponent("tone.wav")
        let mp4 = dir.appendingPathComponent("clip.mp4")
        let ff = try MediaEngine.ffmpeg()
        try await Shell.run(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", wav.path])
        try await Shell.run(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
                                 "-f", "lavfi", "-i", "sine=duration=2", "-shortest", "-pix_fmt", "yuv420p", mp4.path])
        for ext in ["mp3", "m4a", "flac", "ogg", "opus", "aiff", "wma"] { _ = try await run(.mediaTo(ext), [wav]) }
        for ext in ["mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"] { _ = try await run(.mediaTo(ext), [mp4]) }
        for tool in [MediaTool.compressVideo, .extractAudio, .mute, .videoToGIF, .halfSize, .rotate, .thumbnail, .speedUp] {
            _ = try await run(.mediaTool(tool), [mp4])
        }
        for tool in [MediaTool.compressAudio, .normalize, .speedUp] { _ = try await run(.mediaTool(tool), [wav]) }
        _ = try await run(.mediaTool(.merge), [mp4, mp4])
        _ = try await run(.mediaTool(.merge), [wav, wav])
    }

    @Test func catalogCoversKinds() {
        let samples = ["a.jpg", "a.mov", "a.mp3", "a.pdf", "a.docx", "a.csv", "a.srt", "a.zip", "a.epub", "a.pptx", "a.svg"]
        for name in samples {
            let ops = Catalog.operations(for: [URL(fileURLWithPath: "/tmp/\(name)")], mode: .convert)
            #expect(!ops.isEmpty, "\(name)")
        }
    }
}

struct LocalizationTests {
    /// Every literal passed to tr() in the app sources must have a Russian translation.
    @Test func everyStringIsTranslated() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Kumquat")
        var missing: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
            let code = try String(contentsOf: file, encoding: .utf8)
            for match in code.matches(of: /tr\("((?:[^"\\]|\\.)*)"/) {
                let key = String(match.1).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
                if L10n.ru[key] == nil { missing.append(key) }
            }
        }
        #expect(missing.isEmpty, "Missing ru: \(missing)")
    }

    @Test func formatsArguments() {
        UserDefaults.standard.set("ru", forKey: AppLanguage.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
        #expect(tr("Convert to %@", "PNG") == "Конвертировать в PNG")
        #expect(tr("%d files", 3) == "Файлов: 3")
        #expect(tr("Untranslated fallback") == "Untranslated fallback")
    }
}

@MainActor
struct PDFToWordTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-pdfword-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Page 1: A4 portrait with a black square in its top-left corner, rotated 90° clockwise.
    /// Page 2: A4 landscape with a black square in its top-left corner.
    func makePDF() throws -> URL {
        let url = dir.appendingPathComponent("sample.pdf")
        let ctx = CGContext(url as CFURL, mediaBox: nil, nil)!
        for size in [CGSize(width: 595, height: 842), CGSize(width: 842, height: 595)] {
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: size.height - 150, width: 150, height: 150))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let doc = PDFDocument(url: url)!
        doc.page(at: 0)!.rotation = 90
        doc.write(to: url)
        return url
    }

    /// Brightness (0…1) of a pixel, with (0, 0) at the image's top-left.
    func brightness(_ image: CGImage, x: Int, y: Int) -> Double {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Double(pixel[0]) / 255
    }

    @Test func renderRespectsRotationAndOrientation() throws {
        let doc = PDFDocument(url: try makePDF())!
        let rotated = try #require(PDFEngine.renderPage(doc.page(at: 0)!, dpi: 72))
        // Portrait page turned 90° clockwise shows as landscape; its top-left mark moves to the top-right.
        #expect(rotated.width == 842 && rotated.height == 595)
        #expect(brightness(rotated, x: 842 - 20, y: 20) < 0.2, "mark should be top-right")
        #expect(brightness(rotated, x: 20, y: 20) > 0.8)

        let landscape = try #require(PDFEngine.renderPage(doc.page(at: 1)!, dpi: 72))
        #expect(landscape.width == 842 && landscape.height == 595)
        #expect(brightness(landscape, x: 20, y: 20) < 0.2, "mark should be top-left")
        #expect(brightness(landscape, x: 842 - 20, y: 595 - 20) > 0.8)
    }

    @Test func wordCopyHasOneImagePerPage() async throws {
        let pdf = try makePDF()
        let out = try await Engine(settings: ConversionSettings()).run(.pdfTo("docx"), inputs: [pdf]) { _ in }
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", out[0].path])
        #expect(listing.contains("word/media/page1.jpg") && listing.contains("word/media/page2.jpg"))
        let xml = try await Shell.run("/usr/bin/unzip", ["-p", out[0].path, "word/document.xml"])
        #expect(xml.components(separatedBy: "<w:sectPr>").count - 1 == 2)
        #expect(xml.components(separatedBy: "w:orient=\"landscape\"").count - 1 == 2)
        #expect((try? XMLDocument(xmlString: xml)) != nil, "document.xml must be well-formed")
        print("DOCX at: \(out[0].path)")
    }
}

@MainActor
struct MetadataTests {
    let dir: URL
    let engine = Engine(settings: ConversionSettings())

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func strip(_ url: URL) async throws -> URL {
        let out = try await engine.run(.stripMetadata, inputs: [url]) { _ in }
        #expect(out[0].lastPathComponent.contains("-clean"))
        #expect(FileManager.default.fileExists(atPath: url.path), "original must stay")
        #expect(extendedAttributes(out[0]).subtracting(["com.apple.provenance"]).isEmpty, "extended attributes must be gone")
        return out[0]
    }

    func extendedAttributes(_ url: URL) -> Set<String> {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        listxattr(url.path, &buffer, size, XATTR_NOFOLLOW)
        return Set(buffer.split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) })
    }

    func tagWithWhereFrom(_ url: URL) {
        setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", "http://example.com", 18, 0, 0)
    }

    @Test func jpegLosesGPSAndCameraButKeepsPixelsAndOrientation() async throws {
        let url = dir.appendingPathComponent("photo.jpg")
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:01 10:00:00"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        tagWithWhereFrom(url)
        #expect(MetadataEngine.hasPrivateMetadata(url))

        let out = try await strip(url)
        #expect(!MetadataEngine.hasPrivateMetadata(out))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyOrientation] as? Int == 6, "orientation must survive")
        // Lossless: the compressed image data is unchanged, so the file is no bigger than before.
        let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let after = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        #expect(after <= before)
    }

    @Test func pdfLosesAuthorAndTitle() async throws {
        let url = dir.appendingPathComponent("doc.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Secret Author", PDFDocumentAttribute.titleAttribute: "Secret Title"]
        doc.write(to: url)
        let out = try await strip(url)
        let attrs = PDFDocument(url: out)!.documentAttributes ?? [:]
        #expect((attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "").isEmpty)
        #expect((attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "").isEmpty)
        let raw = try String(decoding: Data(contentsOf: out), as: UTF8.self)
        #expect(!raw.contains("Secret"))
    }

    @Test func mediaLosesTags() async throws {
        let mp3 = dir.appendingPathComponent("song.mp3")
        let ff = try MediaEngine.ffmpeg()
        try await Shell.run(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=1",
                                 "-metadata", "title=Secret Song", "-metadata", "artist=Secret Artist", mp3.path])
        let out = try await strip(mp3)
        let probe = try await Shell.run(ConverterEnvironment.tool("ffprobe")!, ["-v", "error", "-show_entries", "format_tags", "-of", "default", out.path])
        #expect(!probe.contains("Secret"), "\(probe)")
        #expect(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 1000, "audio must remain")
    }

    @Test func wordLosesAuthor() async throws {
        let md = dir.appendingPathComponent("note.md")
        try "# Hello\n\nBody text.".write(to: md, atomically: true, encoding: .utf8)
        let docx = try await engine.run(.docTo(.docx), inputs: [md]) { _ in }
        // Inject an author and company the way Word stores them.
        try await MetadataEngine.replaceParts(in: docx[0], ["docProps/core.xml": """
            <?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Secret Person</dc:creator></cp:coreProperties>
            """, "docProps/app.xml": """
            <?xml version="1.0" encoding="UTF-8"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Company>Secret Corp</Company><Pages>1</Pages></Properties>
            """])
        let out = try await strip(docx[0])
        let core = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "docProps/core.xml"])
        let app = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "docProps/app.xml"])
        #expect(!core.contains("Secret") && !app.contains("Secret"))
        #expect(app.contains("<Pages>1</Pages>"))
        #expect(try NSAttributedString(url: out, options: [:], documentAttributes: nil).string.contains("Body text"), "document must still open")
    }

    @Test func plainFileLosesExtendedAttributes() async throws {
        let txt = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        tagWithWhereFrom(txt)
        let out = try await strip(txt)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello")
    }

    @Test func toolsWheelOffersItForEveryFileButNotFolders() {
        for name in ["a.jpg", "a.mov", "a.mp3", "a.pdf", "a.docx", "a.csv", "a.zip", "a.txt"] {
            let ops = Catalog.operations(for: [URL(fileURLWithPath: "/tmp/\(name)")], mode: .tools)
            #expect(ops.first?.action == .stripMetadata, "\(name)")
        }
        let folder = Catalog.operations(for: [URL(fileURLWithPath: "/tmp/", isDirectory: true)], mode: .tools)
        #expect(!folder.contains { $0.action == .stripMetadata })
    }
}
