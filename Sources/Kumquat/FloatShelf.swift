import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A floating shelf that holds files so they can be dragged into another app later.
@Observable
final class FloatShelf {
    static let shared = FloatShelf()
    var items: [URL] = []
    private var panel: NSPanel?

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
        show()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        if items.isEmpty { close() }
    }

    func close() {
        items.removeAll()
        panel?.orderOut(nil)
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrame(NSRect(x: vf.maxX - 136, y: vf.midY - 180, width: 120, height: 360), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ShelfView(shelf: self))
        return panel
    }
}

struct ShelfView: View {
    let shelf: FloatShelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "tray.full").foregroundStyle(WheelView.accent)
                Spacer()
                Button { shelf.close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Clear shelf"))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(shelf.items, id: \.self) { url in
                        VStack(spacing: 2) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 48, height: 48)
                            Text(url.lastPathComponent).font(.system(size: 9.5)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .contextMenu {
                            Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button(tr("Remove from Shelf")) { shelf.remove(url) }
                        }
                    }
                }
            }
            Text(tr("Drag out to use")).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? WheelView.accent : .clear, lineWidth: 2))
        .id(AppSettings.shared.language)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in FloatShelf.shared.add([url]) }
                }
            }
            return true
        }
    }
}
