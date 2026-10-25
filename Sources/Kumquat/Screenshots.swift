import AppKit
import SwiftUI

/// `Kumquat --screenshots <folder>` renders App Store screenshots (2880×1800) from the real views,
/// in English and Russian.
enum Screenshots {
    static let size = CGSize(width: 1440, height: 900)

    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = makeSampleFiles()
        let previous = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        for language in [AppLanguage.en, .ru] {
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            let shots: [(String, AnyView)] = [
                ("1-convert", AnyView(Slide(title: tr("Drag. Tap ⇧. Drop."),
                                            subtitle: tr("Convert any file without opening an app."),
                                            content: AnyView(DesktopScene(file: samples.photo, mode: .convert, hovered: 1))))),
                ("2-tools", AnyView(Slide(title: tr("Tools under ⌘"),
                                          subtitle: tr("Compress, cut out backgrounds, blur faces, erase metadata."),
                                          content: AnyView(DesktopScene(file: samples.photo, mode: .tools, hovered: 0))))),
                ("3-video", AnyView(Slide(title: tr("Video and audio, too"),
                                          subtitle: tr("MP4, MOV, WebM, GIF, MP3, FLAC and more — all on your Mac."),
                                          content: AnyView(DesktopScene(file: samples.video, mode: .convert, hovered: 2))))),
                ("4-window", AnyView(Slide(title: tr("Prefer clicking? Use the window."),
                                           subtitle: tr("Drop files in, pick a format. Results land next to the originals."),
                                           content: AnyView(WindowScene(files: [samples.photo, samples.photo2]))))),
                ("5-private", AnyView(Slide(title: tr("Your files never leave your Mac"),
                                            subtitle: tr("No uploads, no accounts. Everything is converted locally."),
                                            content: AnyView(DesktopScene(file: samples.pdf, mode: .convert, hovered: 0))))),
            ]
            for (name, view) in shots {
                let url = folder.appendingPathComponent("\(language.rawValue)-\(name).png")
                if let data = png(of: view) { try? data.write(to: url) }
                print("wrote \(url.lastPathComponent)")
            }
        }
        if let previous { UserDefaults.standard.set(previous, forKey: AppLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
    }

    struct Samples { var photo: URL; var photo2: URL; var video: URL; var pdf: URL }

    /// Real (empty) files so Finder supplies the right icons.
    static func makeSampleFiles() -> Samples {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return url
        }
        return Samples(photo: file("holiday.heic"), photo2: file("landscape.jpg"), video: file("weekend.mov"), pdf: file("field-notes.pdf"))
    }

    /// Renders through an offscreen window so AppKit-backed controls draw like they do on screen.
    static func png(of view: AnyView) -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

private struct Slide: View {
    let title: String
    let subtitle: String
    let content: AnyView

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.45), Color(red: 0.97, green: 0.45, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Text(title).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                content.padding(.top, 26)
            }
            .padding(.top, 50)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A slice of desktop with a file being dragged and the wheel open around the cursor.
private struct DesktopScene: View {
    let file: URL
    let mode: WheelMode
    let hovered: Int

    var body: some View {
        let model = WheelModel()
        model.mode = mode
        model.files = [file]
        model.all = Catalog.operations(for: [file], mode: mode)
        model.hovered = hovered
        return ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.33, green: 0.27, blue: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.25)))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            ZStack {
                Circle().fill(.white.opacity(0.92)).frame(width: WheelController.outerRadius * 2 + 12)
                WheelView(model: model)
            }
            .environment(\.colorScheme, .light)
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 64, height: 64)
                Text(file.lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 6).background(Color.accentColor.opacity(0.85), in: Capsule())
            }
            .offset(cursorOffset(segments: model.operations.count))
            .opacity(0.9)
        }
        .frame(width: 1060, height: 600)
    }

    /// Puts the dragged file over the highlighted slice, where the cursor would be on drop.
    private func cursorOffset(segments: Int) -> CGSize {
        let angle = (Double(hovered) * 360 / Double(max(segments, 1)) - 90) * .pi / 180
        // Past the labels, on the rim: drops there still count for the slice.
        let radius = WheelController.outerRadius + 30
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius + 20)
    }
}

/// The main window with files dropped in, inside a light window frame.
private struct WindowScene: View {
    let files: [URL]

    var body: some View {
        MainState.shared.files = files
        MainState.shared.mode = .convert
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                Spacer()
                Text("Kumquat").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 14).frame(height: 36).background(Color(white: 0.95))
            MainView().fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
    }
}
