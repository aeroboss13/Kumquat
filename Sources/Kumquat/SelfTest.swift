import AppKit
import PDFKit

/// `Kumquat --selftest` runs the main conversions on generated files inside the app's own temporary
/// folder and prints one line per check. Used to verify a build under the App Sandbox, where helper
/// tools, child processes and file access behave differently than in tests.
enum SelfTest {
    static func run() async -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = Engine(settings: ConversionSettings())
        var passed = 0, failed = 0

        func check(_ name: String, _ body: () async throws -> [URL]) async {
            do {
                let outputs = try await body()
                let ok = !outputs.isEmpty && outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                print(ok ? "PASS \(name)" : "FAIL \(name): no output")
                ok ? (passed += 1) : (failed += 1)
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                failed += 1
            }
        }

        print("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        print("ffmpeg: \(ConverterEnvironment.tool("ffmpeg") ?? "missing")")

        // Inputs
        let png = dir.appendingPathComponent("image.png")
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 280, height: 160))
        try? ImageEngine.write(ctx.makeImage()!, to: png, format: .png, quality: 1)
        let md = dir.appendingPathComponent("notes.md")
        try? "# Title\n\nSome **bold** text.\n\n- one\n- two".write(to: md, atomically: true, encoding: .utf8)

        await check("image → webp (ffmpeg)") { try await engine.run(.imageTo(.webp), inputs: [png]) { _ in } }
        await check("image → avif") { try await engine.run(.imageTo(.avif), inputs: [png]) { _ in } }
        await check("image → heic") { try await engine.run(.imageTo(.heic), inputs: [png]) { _ in } }
        await check("strip metadata") { try await engine.run(.stripMetadata, inputs: [png]) { _ in } }

        var video: URL?
        await check("generate video (ffmpeg)") {
            let url = dir.appendingPathComponent("clip.mov")
            try await Shell.run(try MediaEngine.ffmpeg(), ["-y", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25", "-f", "lavfi", "-i", "sine=duration=2",
                "-shortest", "-c:v", "h264_videotoolbox", "-c:a", "aac_at", url.path])
            video = url
            return [url]
        }
        if let video {
            for ext in ["mp4", "webm", "mkv", "gif", "mp3"] {
                await check("video → \(ext)") { try await engine.run(.mediaTo(ext), inputs: [video]) { _ in } }
            }
            await check("video compress") { try await engine.run(.mediaTool(.compressVideo), inputs: [video]) { _ in } }
            await check("extract audio") { try await engine.run(.mediaTool(.extractAudio), inputs: [video]) { _ in } }
            if let mp3 = try? await engine.run(.mediaTo("mp3"), inputs: [video], progress: { _ in }).first {
                for ext in ["ogg", "opus", "flac", "wav", "m4a"] {
                    await check("audio → \(ext)") { try await engine.run(.mediaTo(ext), inputs: [mp3]) { _ in } }
                }
            }
        }

        var docx: URL?
        await check("markdown → docx") { let out = try await engine.run(.docTo(.docx), inputs: [md]) { _ in }; docx = out.first; return out }
        await check("markdown → pdf") { try await engine.run(.docTo(.pdf), inputs: [md]) { _ in } }
        await check("markdown → epub (zip)") { try await engine.run(.docTo(.epub), inputs: [md]) { _ in } }
        if let pdf = try? await engine.run(.docTo(.pdf), inputs: [md], progress: { _ in }).first {
            await check("pdf → docx (page images)") { try await engine.run(.pdfTo("docx"), inputs: [pdf]) { _ in } }
            await check("pdf → png") { try await engine.run(.pdfTo("png"), inputs: [pdf]) { _ in } }
        }
        if let docx { await check("strip docx metadata (zip)") { try await engine.run(.stripMetadata, inputs: [docx]) { _ in } } }

        var archive: URL?
        await check("zip (ditto)") { let out = try await engine.run(.archive(.zip), inputs: [png]) { _ in }; archive = out.first; return out }
        await check("tar.gz (tar)") { try await engine.run(.archive(.tgz), inputs: [png]) { _ in } }
        if let archive { await check("extract zip") { try await engine.run(.extract, inputs: [archive]) { _ in } } }

        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
