import AppKit
import Observation
import ServiceManagement
import SwiftUI

// MARK: - Settings

enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option, none
    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        case .none: []
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .none: "–"
        }
    }

    var title: String { self == .none ? tr("Off") : "\(symbol) \(rawValue.capitalized)" }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToOriginal: tr("Next to the original")
        case .downloads: tr("Downloads")
        case .custom: tr("Custom folder…")
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var convertKey: ModifierKey { didSet { defaults.set(convertKey.rawValue, forKey: "convertKey") } }
    var toolsKey: ModifierKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    var actionsKey: ModifierKey { didSet { defaults.set(actionsKey.rawValue, forKey: "actionsKey") } }
    var outputLocation: OutputLocation { didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") } }
    var customFolder: URL? { didSet { defaults.set(customFolder, forKey: "customFolder") } }
    var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    var revealAfter: Bool { didSet { defaults.set(revealAfter, forKey: "revealAfter") } }
    var gestureEnabled: Bool { didSet { defaults.set(gestureEnabled, forKey: "gestureEnabled") } }
    var useITerm: Bool { didSet { defaults.set(useITerm, forKey: "useITerm") } }
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey) } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("Launch at login: \(error)") }
        }
    }

    private init() {
        defaults.register(defaults: ["quality": 0.82, "playSound": true, "gestureEnabled": true])
        convertKey = ModifierKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModifierKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = ModifierKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .nextToOriginal
        customFolder = defaults.url(forKey: "customFolder")
        quality = defaults.double(forKey: "quality")
        playSound = defaults.bool(forKey: "playSound")
        revealAfter = defaults.bool(forKey: "revealAfter")
        gestureEnabled = defaults.bool(forKey: "gestureEnabled")
        useITerm = defaults.bool(forKey: "useITerm")
        language = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
    }

    func mode(for key: NSEvent.ModifierFlags) -> WheelMode? {
        if convertKey != .none, key.contains(convertKey.flag) { return .convert }
        if toolsKey != .none, key.contains(toolsKey.flag) { return .tools }
        if actionsKey != .none, key.contains(actionsKey.flag) { return .actions }
        return nil
    }

    func key(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .convert: convertKey
        case .tools: toolsKey
        case .actions: actionsKey
        }
    }

    var conversionSettings: ConversionSettings {
        let dir: URL? = switch outputLocation {
        case .nextToOriginal: nil
        case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .custom: customFolder
        }
        return ConversionSettings(outputDirectory: dir, quality: quality)
    }
}

// MARK: - Jobs

@Observable
final class JobCenter {
    static let shared = JobCenter()

    struct Job: Identifiable {
        enum State { case running(Double), done([URL]), failed(String) }
        let id = UUID()
        let title: String
        let inputs: [URL]
        var state: State
        let date = Date()
        var task: Task<Void, Never>?

        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    private(set) var jobs: [Job] = []

    func perform(_ operation: Operation, on urls: [URL]) {
        if case .fileAction(let action) = operation.action {
            FileActions.perform(action, on: urls)
            return
        }
        let name = urls.count == 1 ? urls[0].lastPathComponent : tr("%d files", urls.count)
        var job = Job(title: "\(operation.detail) · \(name)", inputs: urls, state: .running(0))
        let id = job.id
        var settings = AppSettings.shared.conversionSettings
        // In the sandbox the destination folder may need a grant; if the user declines, use Downloads.
        let destinations = settings.outputDirectory.map { [$0] } ?? urls.map { $0.deletingLastPathComponent() }
        if !FileAccess.shared.ensureWritable(destinations) {
            settings.outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        let engine = Engine(settings: settings)
        job.task = Task {
            do {
                let outputs = try await engine.run(operation.action, inputs: urls) { value in
                    Task { @MainActor in JobCenter.shared.update(id, .running(value)) }
                }
                finish(id, .done(outputs))
            } catch is CancellationError {
                finish(id, .failed(tr("Cancelled")))
            } catch {
                finish(id, .failed(error.localizedDescription))
            }
        }
        jobs.insert(job, at: 0)
        if jobs.count > 50 { jobs.removeLast(jobs.count - 50) }
        HUD.shared.show(jobID: id)
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func cancel(_ id: UUID) { job(id)?.task?.cancel() }

    func clearFinished() { jobs.removeAll { !$0.isRunning } }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning else { return }
        jobs[i].state = state
    }

    private func finish(_ id: UUID, _ state: Job.State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state
        let settings = AppSettings.shared
        switch state {
        case .done(let urls):
            if settings.playSound { NSSound(named: "Glass")?.play() }
            if settings.revealAfter, !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .failed:
            if settings.playSound { NSSound(named: "Basso")?.play() }
        case .running: break
        }
        HUD.shared.jobFinished(id)
    }
}

// MARK: - File actions

enum FileActions {
    static func perform(_ action: FileAction, on urls: [URL]) {
        switch action {
        case .airdrop:
            NSApp.activate()
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .float:
            FloatShelf.shared.add(urls)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            HUD.shared.flash(tr("Copied %@", urls.count == 1 ? urls[0].lastPathComponent : tr("%d items", urls.count)), symbol: "doc.on.doc")
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.flash(tr("Path copied"), symbol: "link")
        case .move:
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = tr("Move Here")
            panel.message = tr("Move %@ to…", urls.count == 1 ? urls[0].lastPathComponent : tr("%d items", urls.count))
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            // Moving also writes to the source folders, which the sandbox may not cover yet.
            guard FileAccess.shared.ensureWritable(urls.map { $0.deletingLastPathComponent() }) else { return }
            var moved: [URL] = []
            for url in urls {
                let target = OutputNamer.unique(dest.appendingPathComponent(url.lastPathComponent))
                do { try FileManager.default.moveItem(at: url, to: target); moved.append(target) }
                catch { NSAlert(error: error).runModal() }
            }
            if !moved.isEmpty { HUD.shared.flash(tr("Moved to %@", dest.lastPathComponent), symbol: "folder") }
        case .terminal:
            let url = urls[0]
            let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let iTerm = URL(fileURLWithPath: "/Applications/iTerm.app")
            let app = AppSettings.shared.useITerm && FileManager.default.fileExists(atPath: iTerm.path)
                ? iTerm : URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
