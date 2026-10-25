import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct KumquatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kumquat", id: "main") {
            MainView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: JobCenter.shared.jobs.contains(where: \.isRunning) ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count {
            Screenshots.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { exit(await SelfTest.run() ? 0 : 1) }
            return
        }
        FileAccess.shared.restore()
        DragWatcher.shared.start()
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
        } else {
            // After the first run, start quietly in the menu bar.
            DispatchQueue.main.async { NSApp.windows.first { $0.identifier?.rawValue == "main" }?.close() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainState.shared.files = urls
        NSApp.activate()
    }
}

// MARK: - Main window

@Observable
final class MainState {
    static let shared = MainState()
    var files: [URL] = []
    var mode: WheelMode = .convert
}

struct MainView: View {
    @State private var state = MainState.shared
    @State private var targeted = false
    private let settings = AppSettings.shared
    private let jobs = JobCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            if ConverterEnvironment.isAppStore && !FileAccess.shared.hasHomeAccess {
                accessBanner.padding([.horizontal, .top], 20)
            }
            dropZone.padding(20)
            if !state.files.isEmpty {
                Picker("", selection: $state.mode) {
                    ForEach(WheelMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
                operationsGrid.padding(20)
            }
            Divider()
            recent
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .background(.background)
        .id(settings.language)
    }

    /// Sandbox onboarding: one grant of the home folder lets results land next to originals everywhere.
    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.person.crop").font(.title2).foregroundStyle(WheelView.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Allow access to your home folder")).font(.callout.weight(.semibold))
                Text(tr("So Kumquat can save converted files next to the originals. Files never leave your Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(tr("Allow…")) {
                FileAccess.shared.requestAccess(message: tr("Select your home folder and click Allow Access."))
            }
        }
        .padding(12)
        .background(WheelView.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            if state.files.isEmpty {
                Image(systemName: "arrow.down.doc").font(.system(size: 40, weight: .light)).foregroundStyle(WheelView.accent)
                Text(tr("Drop files here")).font(.title2.weight(.semibold))
                VStack(spacing: 6) {
                    hint(settings.convertKey, tr("Convert formats"))
                    hint(settings.toolsKey, tr("File tools"))
                    hint(settings.actionsKey, tr("File actions"))
                }
                Text(tr("…or start dragging a file anywhere and tap a key.\nDrop it on a slice of the wheel — the result lands next to the original."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(tr("Choose Files…"), action: choose).controlSize(.large)
            } else {
                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.files, id: \.self) { url in
                                VStack(spacing: 4) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                                    Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 84)
                                }
                            }
                        }
                    }
                    Button { state.files = [] } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Clear"))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: state.files.isEmpty ? 260 : 90)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? WheelView.accent.opacity(0.12) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .foregroundStyle(targeted ? WheelView.accent : .secondary.opacity(0.4)))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) { urls.append(fileURL) }
                }
                state.files = urls
            }
            return true
        }
    }

    private func hint(_ key: ModifierKey, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(key.symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 26, height: 22).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(.callout)
        }
    }

    private var operationsGrid: some View {
        let ops = Catalog.operations(for: state.files, mode: state.mode)
        return Group {
            if ops.isEmpty {
                Text(tr("No options for this selection.")).foregroundStyle(.secondary).frame(height: 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(ops) { op in
                        Button { jobs.perform(op, on: state.files) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: op.symbol).font(.system(size: 18, weight: .medium))
                                Text(op.title).font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(op.detail)
                    }
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Recent")).font(.headline)
                Spacer()
                if jobs.jobs.contains(where: { !$0.isRunning }) {
                    Button(tr("Clear")) { jobs.clearFinished() }.buttonStyle(.link)
                }
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).padding(.leading, 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            if jobs.jobs.isEmpty {
                Text(tr("Converted files will show up here.")).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(jobs.jobs) { JobRow(job: $0) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 14)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { state.files = panel.urls }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    private let jobs = JobCenter.shared
    private let settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kumquat").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { settings.gestureEnabled }, set: { settings.gestureEnabled = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().help(tr("Drag gesture"))
            }
            Text(tr("Drag a file, tap %@, drop on the wheel.", "\(settings.convertKey.symbol) \(settings.toolsKey.symbol) \(settings.actionsKey.symbol)"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if jobs.jobs.isEmpty {
                Text(tr("No conversions yet")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) { ForEach(jobs.jobs.prefix(12)) { JobRow(job: $0) } }
                }
                .frame(maxHeight: 280)
            }
            Divider()
            HStack {
                Button(tr("Open Window")) { openWindow(id: "main"); NSApp.activate() }
                SettingsLink { Text(tr("Settings…")) }
                Spacer()
                Button(tr("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .id(settings.language)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin

    var body: some View {
        Form {
            Section(tr("Language")) {
                Picker(tr("Interface language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            Section(tr("Wheel keys — tap while dragging")) {
                Picker(tr("Convert formats"), selection: $settings.convertKey) { keyOptions }
                Picker(tr("File tools"), selection: $settings.toolsKey) { keyOptions }
                Picker(tr("File actions"), selection: $settings.actionsKey) { keyOptions }
                Toggle(tr("Enable drag gesture"), isOn: $settings.gestureEnabled)
            }
            Section(tr("Output")) {
                Picker(tr("Save converted files"), selection: $settings.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.outputLocation) { _, new in
                    if new == .custom { pickFolder() }
                }
                if settings.outputLocation == .custom {
                    LabeledContent(tr("Folder")) {
                        Button(settings.customFolder?.lastPathComponent ?? tr("Choose…"), action: pickFolder)
                    }
                }
                LabeledContent(tr("Image quality")) {
                    HStack {
                        Slider(value: $settings.quality, in: 0.4...1.0)
                        Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Toggle(tr("Reveal results in Finder"), isOn: $settings.revealAfter)
                Toggle(tr("Play sound when done"), isOn: $settings.playSound)
            }
            Section(tr("General")) {
                Toggle(tr("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in settings.launchAtLogin = new }
                Toggle(tr("Open folders in iTerm instead of Terminal"), isOn: $settings.useITerm)
            }
            if ConverterEnvironment.isAppStore {
                Section(tr("File access")) {
                    ForEach(FileAccess.shared.grantedFolders, id: \.self) { url in
                        Label(url.path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    }
                    if FileAccess.shared.grantedFolders.isEmpty {
                        Text(tr("No folders yet. Kumquat asks the first time it saves into a folder.")).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(tr("Add Folder…")) { FileAccess.shared.requestAccess(message: tr("Choose a folder Kumquat may save into.")) }
                        Spacer()
                        if !FileAccess.shared.grantedFolders.isEmpty {
                            Button(tr("Remove All"), role: .destructive) { FileAccess.shared.revokeAll() }
                        }
                    }
                }
            } else {
                Section(tr("Helpers")) {
                    helper("ffmpeg", tr("Audio & video"))
                    helper("cwebp", tr("WebP export (falls back to ffmpeg)"))
                    helper("7z", tr("RAR / 7z extraction"))
                    LabeledContent("Pages") {
                        Text(tr(ConverterEnvironment.pagesAvailable ? "Installed" : "Not installed — .pages export disabled"))
                            .foregroundStyle(ConverterEnvironment.pagesAvailable ? .green : .secondary)
                    }
                }
            }
            if Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") != nil {
                Section {
                    Button(tr("Open-source licenses")) {
                        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .id(settings.language)
    }

    private var keyOptions: some View {
        ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
    }

    private func helper(_ tool: String, _ purpose: String) -> some View {
        LabeledContent(tool) {
            if ConverterEnvironment.tool(tool) != nil {
                Label(tr("Found"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("brew install \(tool == "7z" ? "sevenzip" : tool == "cwebp" ? "webp" : tool)").font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .help(purpose)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            FileAccess.shared.add(url)
            settings.customFolder = url
        }
        else if settings.customFolder == nil { settings.outputLocation = .nextToOriginal }
    }
}
