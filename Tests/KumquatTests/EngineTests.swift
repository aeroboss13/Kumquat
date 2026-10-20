import AppKit
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

    @Test(arguments: [ImageTool.compress, .resizeHalf, .stripMetadata, .rotate, .flip, .grayscale, .enhance, .cropSquare, .addBackground])
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
