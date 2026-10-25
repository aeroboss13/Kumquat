import AppKit
import Observation

/// The App Store build runs in the App Sandbox: it may only touch files the user dropped or opened,
/// and folders the user granted. Results are written next to the original, so its folder needs a grant.
/// Grants are kept as security-scoped bookmarks so they survive relaunches.
@Observable
final class FileAccess {
    static let shared = FileAccess()
    private let defaultsKey = "folderBookmarks"
    private(set) var grantedFolders: [URL] = []

    /// Re-opens every saved grant. Call once at launch.
    func restore() {
        let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var refreshed: [Data] = []
        for data in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                     bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() else { continue }
            grantedFolders.append(url)
            refreshed.append(stale ? (try? url.bookmarkData(options: [.withSecurityScope])) ?? data : data)
        }
        UserDefaults.standard.set(refreshed, forKey: defaultsKey)
    }

    var hasHomeAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return grantedFolders.contains { $0.standardizedFileURL.path == home }
    }

    /// Whether files can be created in `folder` right now (sandbox grants included).
    nonisolated static func isWritable(_ folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(".kumquat-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Asks the user to grant a folder; `suggested` is preselected. Returns the granted folder.
    @discardableResult
    func requestAccess(suggested: URL? = nil, message: String) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = suggested ?? FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = tr("Allow Access")
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        add(url)
        return url
    }

    func add(_ url: URL) {
        guard !grantedFolders.contains(url), let data = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        _ = url.startAccessingSecurityScopedResource()
        grantedFolders.append(url)
        var saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: defaultsKey)
    }

    func revokeAll() {
        grantedFolders.forEach { $0.stopAccessingSecurityScopedResource() }
        grantedFolders.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Makes sure results can be written into each folder, asking once per folder that isn't covered yet.
    /// Returns false if the user declined, so the caller can fall back to Downloads.
    func ensureWritable(_ folders: [URL]) -> Bool {
        for folder in Set(folders) where !Self.isWritable(folder) {
            let message = tr("Kumquat saves results next to the original. Allow access to “%@” — or choose your home folder to cover every folder at once.",
                             folder.lastPathComponent)
            requestAccess(suggested: folder, message: message)
            if !Self.isWritable(folder) { return false }
        }
        return true
    }
}
