import Foundation

/// Audio and video through ffmpeg, with live progress from `-progress pipe:1`.
nonisolated enum MediaEngine {
    static func ffmpeg() throws -> String {
        guard let path = ConverterEnvironment.tool("ffmpeg") else { throw ConversionError.missingTool("ffmpeg") }
        return path
    }

    /// Reads the stream summary ffmpeg prints for an input; saves shipping a separate ffprobe.
    static func probe(_ url: URL) async -> String {
        guard let ffmpeg = ConverterEnvironment.tool("ffmpeg") else { return "" }
        return await Shell.capture(ffmpeg, ["-hide_banner", "-i", url.path])
    }

    /// H.264 through Apple's hardware encoder: present in every ffmpeg on a Mac, unlike the GPL-only x264.
    /// `quality` is VideoToolbox constant quality, 1–100.
    static func h264(quality: Int) -> [String] {
        ["-c:v", "h264_videotoolbox", "-q:v", String(quality), "-allow_sw", "1", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
    }

    static func duration(of url: URL) async -> Double? {
        guard let m = await probe(url).firstMatch(of: /Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/),
              let h = Double(m.1), let min = Double(m.2), let s = Double(m.3) else { return nil }
        return h * 3600 + min * 60 + s
    }

    static func hasVideo(_ url: URL) async -> Bool {
        // Cover art in audio files shows up as an attached-picture video stream; that doesn't count.
        await probe(url).split(separator: "\n").contains { $0.contains("Video:") && !$0.contains("attached pic") }
    }

    static func run(input: URL, output: URL, args: [String], inputArgs: [String] = [], speedFactor: Double = 1,
                    progress: @escaping ProgressHandler) async throws {
        let total = (await duration(of: input) ?? 0) / speedFactor
        let full = ["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]
            + inputArgs + ["-i", input.path] + args + [output.path]
        do {
            try await Shell.run(try ffmpeg(), full) { line in
                guard total > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                progress(us / 1_000_000 / total)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func convert(_ url: URL, to ext: String, directory: URL?, progress: @escaping ProgressHandler) async throws -> URL {
        let out = OutputNamer.url(for: url, ext: ext, directory: directory)
        let args: [String] = switch ext {
        case "mp4": h264(quality: 65) + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov": h264(quality: 65) + ["-c:a", "aac", "-b:a", "192k"]
        case "mkv": h264(quality: 65) + ["-c:a", "aac", "-b:a", "192k"]
        case "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif": gifArgs
        case "mp3": ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": ["-vn", "-c:a", "pcm_s16be"]
        case "flac": ["-vn", "-c:a", "flac"]
        case "ogg": ["-vn", "-c:a", "libvorbis", "-q:a", "6"]
        case "opus": ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "wma": ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default: []
        }
        try await run(input: url, output: out, args: args, progress: progress)
        return out
    }

    static let gifArgs = ["-vf", "fps=15,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4", "-loop", "0"]

    static func apply(_ tool: MediaTool, to url: URL, directory: URL?, progress: @escaping ProgressHandler) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        func out(_ suffix: String, _ newExt: String? = nil) -> URL {
            OutputNamer.url(for: url, ext: newExt ?? ext, suffix: suffix, directory: directory)
        }
        let video = h264(quality: 65) + ["-c:a", "aac", "-b:a", "160k"]
        let target: URL
        switch tool {
        case .compressVideo:
            target = out("-compressed", "mp4")
            try await run(input: url, output: target, args: [
                "-vf", "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
            ] + h264(quality: 45) + [
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"], progress: progress)
        case .extractAudio:
            target = out("", "m4a")
            try await run(input: url, output: target, args: ["-vn", "-c:a", "aac", "-b:a", "256k"], progress: progress)
        case .mute:
            target = out("-muted")
            try await run(input: url, output: target, args: ["-an", "-c:v", "copy"], progress: progress)
        case .videoToGIF:
            target = out("", "gif")
            try await run(input: url, output: target, args: gifArgs, progress: progress)
        case .halfSize:
            target = out("-half", "mp4")
            try await run(input: url, output: target, args: ["-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2"] + video, progress: progress)
        case .rotate:
            target = out("-rotated", "mp4")
            try await run(input: url, output: target, args: ["-vf", "transpose=1"] + video, progress: progress)
        case .speedUp:
            if await hasVideo(url), FileKind.of(url) == .video {
                target = out("-2x", "mp4")
                try await run(input: url, output: target, args: ["-filter_complex", "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]",
                                                                 "-map", "[v]", "-map", "[a]?"] + video, speedFactor: 2, progress: progress)
            } else {
                target = out("-2x")
                try await run(input: url, output: target, args: ["-filter:a", "atempo=2.0"], speedFactor: 2, progress: progress)
            }
        case .thumbnail:
            target = out("-frame", "jpg")
            let d = await duration(of: url) ?? 0
            try await run(input: url, output: target, args: ["-frames:v", "1", "-q:v", "2"],
                          inputArgs: ["-ss", String(format: "%.2f", min(1, d / 2))], progress: progress)
        case .compressAudio:
            target = out("-compressed", "mp3")
            try await run(input: url, output: target, args: ["-vn", "-c:a", "libmp3lame", "-b:a", "128k"], progress: progress)
        case .normalize:
            let audioExt = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"].contains(ext) ? ext : "m4a"
            target = out("-normalized", audioExt)
            try await run(input: url, output: target, args: ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"], progress: progress)
        case .merge:
            target = try await merge([url], directory: directory, progress: progress)
        }
        return target
    }

    /// Concatenates inputs, re-encoding so mismatched codecs and sizes still join cleanly.
    static func merge(_ urls: [URL], directory: URL?, progress: @escaping ProgressHandler) async throws -> URL {
        let isVideo = FileKind.of(urls[0]) == .video
        let ext = isVideo ? "mp4" : (urls[0].pathExtension.lowercased() == "wav" ? "wav" : "m4a")
        let out = OutputNamer.url(named: "Merged", ext: ext, in: directory ?? urls[0].deletingLastPathComponent())
        var inputs: [String] = []
        for url in urls { inputs += ["-i", url.path] }
        var filter = ""
        var total = 0.0
        for (i, url) in urls.enumerated() {
            total += await duration(of: url) ?? 0
            filter += isVideo
                ? "[\(i):v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)];[\(i):a]aresample=48000[a\(i)];"
                : "[\(i):a]aresample=48000[a\(i)];"
        }
        filter += urls.indices.map { isVideo ? "[v\($0)][a\($0)]" : "[a\($0)]" }.joined()
        filter += "concat=n=\(urls.count):v=\(isVideo ? 1 : 0):a=1" + (isVideo ? "[v][a]" : "[a]")
        let map = isVideo ? ["-map", "[v]", "-map", "[a]"] + h264(quality: 65) + ["-c:a", "aac"]
                          : ["-map", "[a]"] + (ext == "wav" ? [] : ["-c:a", "aac", "-b:a", "256k"])
        let args = ["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + inputs
            + ["-filter_complex", filter] + map + [out.path]
        let duration = total
        do {
            try await Shell.run(try ffmpeg(), args) { line in
                guard duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                progress(us / 1_000_000 / duration)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}
