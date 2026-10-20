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
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            if state.files.isEmpty {
                Image(systemName: "arrow.down.doc").font(.system(size: 40, weight: .light)).foregroundStyle(WheelView.accent)
                Text("Drop files here").font(.title2.weight(.semibold))
                VStack(spacing: 6) {
                    hint(settings.convertKey, "Convert formats")
                    hint(settings.toolsKey, "File tools")
                    hint(settings.actionsKey, "File actions")
                }
                Text("…or start dragging a file anywhere and tap a key.\nDrop it on a slice of the wheel — the result lands next to the original.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Choose Files…", action: choose).controlSize(.large)
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
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
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
                Text("No options for this selection.").foregroundStyle(.secondary).frame(height: 80)
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
                Text("Recent").font(.headline)
                Spacer()
                if jobs.jobs.contains(where: { !$0.isRunning }) {
                    Button("Clear") { jobs.clearFinished() }.buttonStyle(.link)
                }
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).padding(.leading, 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            if jobs.jobs.isEmpty {
                Text("Converted files will show up here.").font(.callout).foregroundStyle(.secondary)
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
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().help("Drag gesture")
            }
            Text("Drag a file, tap \(settings.convertKey.symbol) \(settings.toolsKey.symbol) \(settings.actionsKey.symbol), drop on the wheel.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if jobs.jobs.isEmpty {
                Text("No conversions yet").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) { ForEach(jobs.jobs.prefix(12)) { JobRow(job: $0) } }
                }
                .frame(maxHeight: 280)
            }
            Divider()
            HStack {
                Button("Open Window") { openWindow(id: "main"); NSApp.activate() }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin

    var body: some View {
        Form {
            Section("Wheel keys — tap while dragging") {
                Picker("Convert formats", selection: $settings.convertKey) { keyOptions }
                Picker("File tools", selection: $settings.toolsKey) { keyOptions }
                Picker("File actions", selection: $settings.actionsKey) { keyOptions }
                Toggle("Enable drag gesture", isOn: $settings.gestureEnabled)
            }
            Section("Output") {
                Picker("Save converted files", selection: $settings.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.outputLocation) { _, new in
                    if new == .custom { pickFolder() }
                }
                if settings.outputLocation == .custom {
                    LabeledContent("Folder") {
                        Button(settings.customFolder?.lastPathComponent ?? "Choose…", action: pickFolder)
                    }
                }
                LabeledContent("Image quality") {
                    HStack {
                        Slider(value: $settings.quality, in: 0.4...1.0)
                        Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Toggle("Reveal results in Finder", isOn: $settings.revealAfter)
                Toggle("Play sound when done", isOn: $settings.playSound)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in settings.launchAtLogin = new }
                Toggle("Open folders in iTerm instead of Terminal", isOn: $settings.useITerm)
            }
            Section("Helpers") {
                helper("ffmpeg", "Audio & video")
                helper("cwebp", "WebP export (falls back to ffmpeg)")
                helper("7z", "RAR / 7z extraction")
                LabeledContent("Pages") {
                    Text(ConverterEnvironment.pagesAvailable ? "Installed" : "Not installed — .pages export disabled")
                        .foregroundStyle(ConverterEnvironment.pagesAvailable ? .green : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }

    private var keyOptions: some View {
        ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
    }

    private func helper(_ tool: String, _ purpose: String) -> some View {
        LabeledContent(tool) {
            if ConverterEnvironment.tool(tool) != nil {
                Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
        if panel.runModal() == .OK { settings.customFolder = panel.url }
        else if settings.customFolder == nil { settings.outputLocation = .nextToOriginal }
    }
}
