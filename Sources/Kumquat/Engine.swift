import Foundation
import os

nonisolated enum ConversionError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case missingTool(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): tr("Couldn't read %@.", name)
        case .unsupported(let what): tr("%@ isn't supported.", what)
        case .missingTool(let tool): tr("%@ is required. Install it with Homebrew: brew install %@", tool, tool)
        case .toolFailed(let message): message
        }
    }
}

/// Snapshot of user preferences handed to the background engine.
nonisolated struct ConversionSettings: Sendable {
    var outputDirectory: URL?
    var quality: Double = 0.8
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Locates optional command-line helpers. Everything core uses system frameworks;
/// audio/video goes through ffmpeg because AVFoundation can't write WebM, MKV, OGG, etc.
nonisolated enum ConverterEnvironment {
    #if APPSTORE
    /// The App Store build is sandboxed and self-contained: only tools inside the bundle and the system's own.
    static let isAppStore = true
    static let searchPaths = ["/usr/bin", "/bin"]
    #else
    static let isAppStore = false
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]
    #endif

    /// Tools shipped inside the app (ffmpeg) win over anything installed on the system.
    static func tool(_ name: String) -> String? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pages and Keynote are driven through AppleScript, which the App Store sandbox doesn't allow.
    static var pagesAvailable: Bool { !isAppStore && FileManager.default.fileExists(atPath: "/Applications/Pages.app") }
    static var keynoteAvailable: Bool { !isAppStore && FileManager.default.fileExists(atPath: "/Applications/Keynote.app") }

    static var officeSuite: String? {
        guard !isAppStore else { return nil }
        let bundled = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return tool("soffice") ?? (FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil)
    }

    static var slidesToPDFAvailable: Bool { keynoteAvailable || officeSuite != nil }
}

nonisolated enum Shell {
    /// Runs a process and returns stdout. `onLine` receives stdout lines as they arrive.
    /// Runs a process and returns stdout and stderr together, whatever its exit status.
    static func capture(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let output = OSAllocatedUnfairLock(initialState: Data())
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                output.withLock { $0.append(chunk) }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                output.withLock { $0.append(rest) }
                continuation.resume(returning: String(decoding: output.withLock { $0 }, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let stdout = OSAllocatedUnfairLock(initialState: Data())
        let stderr = OSAllocatedUnfairLock(initialState: Data())
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stdout.withLock { $0.append(chunk) }
            if let onLine, let text = String(data: chunk, encoding: .utf8) {
                text.split(separator: "\n").forEach { onLine(String($0)) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderr.withLock { $0.append(chunk) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    let rest = out.fileHandleForReading.readDataToEndOfFile()
                    stdout.withLock { $0.append(rest) }
                    let output = String(decoding: stdout.withLock { $0 }, as: UTF8.self)
                    if p.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        let message = String(decoding: stderr.withLock { $0 }, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let lastLines = message.split(separator: "\n").suffix(3).joined(separator: "\n")
                        continuation.resume(throwing: ConversionError.toolFailed(
                            lastLines.isEmpty ? tr("%@ failed (%d)", URL(fileURLWithPath: executable).lastPathComponent, p.terminationStatus) : lastLines))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Picks output file names that never overwrite anything.
nonisolated enum OutputNamer {
    static func url(for input: URL, ext: String, suffix: String = "", directory: URL?) -> URL {
        let dir = directory ?? input.deletingLastPathComponent()
        var base = input.deletingPathExtension().lastPathComponent
        if input.pathExtension.lowercased() == "gz", base.hasSuffix(".tar") { base = String(base.dropLast(4)) }
        return unique(dir.appendingPathComponent(base + suffix).appendingPathExtension(ext))
    }

    static func url(named name: String, ext: String, in directory: URL) -> URL {
        unique(directory.appendingPathComponent(name).appendingPathExtension(ext))
    }

    static func folder(for input: URL, suffix: String, directory: URL?) -> URL {
        let dir = directory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        let url = uniqueFolder(dir.appendingPathComponent(base))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func uniqueFolder(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(n)")
            n += 1
        }
        return candidate
    }
}

/// Entry point for every conversion and tool. Runs off the main actor.
nonisolated struct Engine {
    let settings: ConversionSettings

    @concurrent
    func run(_ action: Action, inputs: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let dir = settings.outputDirectory
        switch action {
        case .imageTo(let format):
            return try await each(inputs, progress) { try ImageEngine.convert($0, to: format, quality: settings.quality, directory: dir) }
        case .imagesToPDF:
            return [try ImageEngine.combineToPDF(inputs, directory: dir)]
        case .collage:
            return [try ImageEngine.collage(inputs, directory: dir)]
        case .imageTool(let tool):
            return try await each(inputs, progress) { try ImageEngine.apply(tool, to: $0, quality: settings.quality, directory: dir) }
        case .mediaTo(let ext):
            return try await eachAsync(inputs, progress) { url, p in try await MediaEngine.convert(url, to: ext, directory: dir, progress: p) }
        case .mediaTool(.merge):
            return [try await MediaEngine.merge(inputs, directory: dir, progress: progress)]
        case .mediaTool(let tool):
            return try await eachAsync(inputs, progress) { url, p in try await MediaEngine.apply(tool, to: url, directory: dir, progress: p) }
        case .pdfTo(let ext):
            return try await eachAsync(inputs, progress) { url, _ in try await DocumentEngine.convertPDF(url, to: ext, directory: dir) }
        case .pdfTool(.merge):
            return [try PDFEngine.merge(inputs, directory: dir)]
        case .pdfTool(let tool):
            return try await each(inputs, progress) { try PDFEngine.apply(tool, to: $0, directory: dir) }
        case .docTo(let format):
            return try await eachAsync(inputs, progress) { url, _ in try await DocumentEngine.convert(url, to: format, directory: dir) }
        case .slidesTo(let ext):
            return try await eachAsync(inputs, progress) { url, _ in try await DocumentEngine.convertSlides(url, to: ext, directory: dir) }
        case .sheetTo(let format):
            return try await eachAsync(inputs, progress) { url, _ in try await SheetEngine.convert(url, to: format, directory: dir) }
        case .subtitleTo(let ext):
            return try await each(inputs, progress) { try SubtitleEngine.convert($0, to: ext, directory: dir) }
        case .archive(let format):
            return [try await ArchiveEngine.compress(inputs, format: format, directory: dir)]
        case .extract:
            return try await eachAsync(inputs, progress) { url, _ in try await ArchiveEngine.extract(url, directory: dir) }
        case .stripMetadata:
            return try await eachAsync(inputs, progress) { url, _ in try await MetadataEngine.strip(url, directory: dir) }
        case .fileAction:
            return []
        }
    }

    private func each(_ inputs: [URL], _ progress: ProgressHandler, _ body: (URL) throws -> URL) async throws -> [URL] {
        var results: [URL] = []
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            results.append(try body(url))
            progress(Double(i + 1) / Double(inputs.count))
        }
        return results
    }

    private func eachAsync(_ inputs: [URL], _ progress: @escaping ProgressHandler,
                           _ body: (URL, @escaping ProgressHandler) async throws -> URL) async throws -> [URL] {
        var results: [URL] = []
        let count = Double(inputs.count)
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let offset = Double(i)
            results.append(try await body(url) { progress((offset + min(max($0, 0), 1)) / count) })
            progress(Double(i + 1) / count)
        }
        return results
    }
}

nonisolated enum ArchiveEngine {
    static func compress(_ inputs: [URL], format: ArchiveFormat, directory: URL?) async throws -> URL {
        let first = inputs[0]
        let parent = first.deletingLastPathComponent()
        let name = inputs.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let outDir = directory ?? parent
        let names = inputs.map(\.lastPathComponent)
        switch format {
        case .zip:
            let out = OutputNamer.url(named: name, ext: "zip", in: outDir)
            if inputs.count == 1 {
                // --keepParent on a plain file would embed its enclosing folder.
                let keepParent = first.hasDirectoryPath ? ["--keepParent"] : []
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + keepParent + [first.path, out.path])
            } else {
                try await Shell.run("/usr/bin/zip", ["-r", "-q", "-y", out.path] + names, currentDirectory: parent)
            }
            return out
        case .tar, .tgz:
            let ext = format == .tar ? "tar" : "tar.gz"
            let out = OutputNamer.unique(outDir.appendingPathComponent("\(name).\(ext)"))
            try await Shell.run("/usr/bin/tar", [format == .tar ? "-cf" : "-czf", out.path, "--no-mac-metadata"] + names, currentDirectory: parent)
            return out
        }
    }

    static func extract(_ url: URL, directory: URL?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let dest = OutputNamer.folder(for: url, suffix: "", directory: directory)
        switch ext {
        case "zip":
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path])
        case "tar", "tgz", "bz2", "xz":
            try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path])
        case "gz":
            if url.deletingPathExtension().pathExtension.lowercased() == "tar" {
                try await Shell.run("/usr/bin/tar", ["-xzf", url.path, "-C", dest.path])
            } else {
                let out = dest.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                try await Shell.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", url.path, out.path])
            }
        case "rar", "7z":
            if let sevenZip = ConverterEnvironment.tool("7z") ?? ConverterEnvironment.tool("7zz") {
                try await Shell.run(sevenZip, ["x", "-y", "-o\(dest.path)", url.path])
            } else if let unar = ConverterEnvironment.tool("unar") {
                try await Shell.run(unar, ["-q", "-o", dest.path, "-f", "-D", url.path])
            } else {
                // The system tar is bsdtar (libarchive), which reads RAR and 7z on its own.
                try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path])
            }
        default:
            throw ConversionError.unsupported(tr(".%@ archives", ext))
        }
        return dest
    }
}
