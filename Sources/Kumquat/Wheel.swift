import AppKit
import SwiftUI

// MARK: - Global drag detection

/// Watches for file drags anywhere on screen without Accessibility permission:
/// polls the mouse button, the drag pasteboard's change count, and the modifier keys.
final class DragWatcher {
    static let shared = DragWatcher()

    private var timer: Timer?
    private var mouseWasDown = false
    private var changeCountAtMouseDown = 0
    private var draggedFiles: [URL]?
    private var lastFlags: NSEvent.ModifierFlags = []
    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { DragWatcher.shared.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !mouseWasDown {
            changeCountAtMouseDown = dragPasteboard.changeCount
            draggedFiles = nil
        }
        if down, draggedFiles == nil, dragPasteboard.changeCount != changeCountAtMouseDown {
            let urls = dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            // Ignore drags that originate from our own floating shelf.
            draggedFiles = urls.isEmpty ? [] : urls
        }
        if !down && mouseWasDown {
            draggedFiles = nil
            WheelController.shared.dragEnded()
        }
        mouseWasDown = down

        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        guard AppSettings.shared.gestureEnabled, !pressed.isEmpty, let files = draggedFiles, !files.isEmpty,
              let mode = AppSettings.shared.mode(for: pressed) else { return }
        WheelController.shared.keyTapped(mode, files: files)
    }
}

// MARK: - Wheel state

@Observable
final class WheelModel {
    var mode: WheelMode = .convert
    var files: [URL] = []
    var all: [Operation] = []
    var page = 0
    var hovered: Int?

    static let perPage = 10

    var pageCount: Int { max(1, Int(ceil(Double(all.count) / Double(Self.perPage)))) }
    var operations: [Operation] {
        Array(all.dropFirst(page * Self.perPage).prefix(Self.perPage))
    }
    var hoveredOperation: Operation? { hovered.flatMap { $0 < operations.count ? operations[$0] : nil } }
}

final class WheelController {
    static let shared = WheelController()
    let model = WheelModel()
    private lazy var panel = WheelPanel(model: model)
    private var hideWork: DispatchWorkItem?

    static let size: CGFloat = 440
    static let innerRadius: CGFloat = 74
    static let outerRadius: CGFloat = 200

    func keyTapped(_ mode: WheelMode, files: [URL]) {
        hideWork?.cancel()
        if panel.isVisible, model.mode == mode, model.files == files {
            // Same key again: next page of options.
            model.page = (model.page + 1) % model.pageCount
            model.hovered = nil
            return
        }
        model.mode = mode
        model.files = files
        model.all = Catalog.operations(for: files, mode: mode)
        model.page = 0
        model.hovered = nil
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            var frame = NSRect(x: mouse.x - Self.size / 2, y: mouse.y - Self.size / 2, width: Self.size, height: Self.size)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
                frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - Self.size)
                frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - Self.size)
            }
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func dragEnded() {
        guard panel.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                self.model.hovered = nil
            }
        }
    }

    /// Maps a point in the panel to a segment, or nil for the center / outside.
    func segment(at point: CGPoint) -> Int? {
        let count = model.operations.count
        guard count > 0 else { return nil }
        let dx = point.x - Self.size / 2, dy = point.y - Self.size / 2
        let distance = hypot(dx, dy)
        guard distance > Self.innerRadius, distance < Self.outerRadius + 30 else { return nil }
        // 0° at the top, clockwise.
        var angle = atan2(dx, dy) * 180 / .pi
        if angle < 0 { angle += 360 }
        let sweep = 360 / Double(count)
        return Int((angle + sweep / 2).truncatingRemainder(dividingBy: 360) / sweep)
    }

    func drop(on index: Int?, files: [URL]) -> Bool {
        defer { hide() }
        guard let index, index < model.operations.count else { return false }
        JobCenter.shared.perform(model.operations[index], on: files.isEmpty ? model.files : files)
        return true
    }
}

// MARK: - Wheel window

final class WheelPanel: NSPanel {
    init(model: WheelModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelController.size, height: WheelController.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        let container = WheelDropView(frame: NSRect(x: 0, y: 0, width: WheelController.size, height: WheelController.size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
}

final class WheelDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Make the drop target the container itself, not the SwiftUI subview.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { WheelController.shared.model.hovered = nil }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let index = WheelController.shared.segment(at: point)
        if WheelController.shared.model.hovered != index {
            withAnimation(.snappy(duration: 0.15)) { WheelController.shared.model.hovered = index }
            if index != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        return index == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return WheelController.shared.drop(on: WheelController.shared.segment(at: point), files: urls)
    }
}

// MARK: - Wheel drawing

nonisolated struct RingSegment: Shape {
    var start: Angle, end: Angle, inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // SwiftUI angles: 0 = east, clockwise in flipped coordinates. Shift so 0 = north.
        let s = start - .degrees(90), e = end - .degrees(90)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: s, endAngle: e, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: e, endAngle: s, clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    let model: WheelModel
    static let accent = Color(red: 1, green: 0.55, blue: 0.15)

    var body: some View {
        let ops = model.operations
        let count = max(ops.count, 1)
        let sweep = 360.0 / Double(count)
        let gap = ops.count > 1 ? 1.2 : 0
        let inner = WheelController.innerRadius, outer = WheelController.outerRadius

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: outer * 2 + 12, height: outer * 2 + 12)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)

            ForEach(Array(ops.enumerated()), id: \.element.id) { index, op in
                let hovered = model.hovered == index
                let mid = Angle.degrees(Double(index) * sweep)
                RingSegment(start: mid - .degrees(sweep / 2 - gap), end: mid + .degrees(sweep / 2 - gap),
                            inner: inner + 4, outer: hovered ? outer + 6 : outer)
                    .fill(hovered ? AnyShapeStyle(Self.accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
                let radius = (inner + outer) / 2 + (hovered ? 3 : 0)
                let rad = (mid.degrees - 90) * .pi / 180
                VStack(spacing: 4) {
                    Image(systemName: op.symbol).font(.system(size: ops.count > 8 ? 16 : 19, weight: .semibold))
                    Text(op.title).font(.system(size: ops.count > 8 ? 10 : 11.5, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: 74)
                .foregroundStyle(hovered ? .white : .primary)
                .offset(x: cos(rad) * radius, y: sin(rad) * radius)
            }

            if ops.isEmpty {
                Text("No options for\nthis file").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .offset(y: -(inner + outer) / 2)
            }

            center(inner: inner)
        }
        .frame(width: WheelController.size, height: WheelController.size)
    }

    private func center(inner: CGFloat) -> some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().strokeBorder(Self.accent.opacity(0.5), lineWidth: 1.5)
            VStack(spacing: 3) {
                if let op = model.hoveredOperation {
                    Image(systemName: op.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Self.accent)
                    Text(op.detail).font(.system(size: 10.5, weight: .medium)).multilineTextAlignment(.center).lineLimit(3)
                } else {
                    Text(AppSettings.shared.key(for: model.mode).symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Self.accent)
                    Text(model.mode.title).font(.system(size: 10.5, weight: .semibold)).multilineTextAlignment(.center)
                    Text(model.files.count == 1 ? model.files[0].lastPathComponent : "\(model.files.count) files")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if model.pageCount > 1 {
                        HStack(spacing: 3) {
                            ForEach(0..<model.pageCount, id: \.self) { i in
                                Circle().fill(i == model.page ? Self.accent : .secondary.opacity(0.4)).frame(width: 4, height: 4)
                            }
                        }.padding(.top, 2)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: inner * 2, height: inner * 2)
    }
}

// MARK: - HUD toast

@Observable
final class HUD {
    static let shared = HUD()
    var jobID: UUID?
    var flashText: String?
    var flashSymbol = "checkmark"
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(jobID: UUID) {
        self.jobID = jobID
        flashText = nil
        present()
    }

    func flash(_ text: String, symbol: String) {
        jobID = nil
        flashText = text
        flashSymbol = symbol
        present()
        scheduleHide(after: 1.6)
    }

    func jobFinished(_ id: UUID) {
        if jobID == id { scheduleHide(after: 4) }
    }

    private func present() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 340, height: 74)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrame(NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismiss() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(hud: self))
        return panel
    }
}

struct HUDView: View {
    let hud: HUD

    var body: some View {
        HStack(spacing: 12) {
            if let id = hud.jobID, let job = JobCenter.shared.job(id) {
                JobRow(job: job, compact: true)
                Button { hud.dismiss() } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else if let text = hud.flashText {
                Image(systemName: hud.flashSymbol).font(.title2).foregroundStyle(WheelView.accent)
                Text(text).font(.callout.weight(.medium)).lineLimit(2)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// One job, shared by the HUD, menu bar and main window.
struct JobRow: View {
    let job: JobCenter.Job
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running(let p):
                    ProgressView(value: p).progressViewStyle(.linear).tint(WheelView.accent)
                case .done(let urls):
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files created")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .failed(let message):
                    Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(compact ? 2 : 3)
                }
            }
            Spacer(minLength: 4)
            switch job.state {
            case .running:
                Button { JobCenter.shared.cancel(job.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).help("Cancel")
            case .done(let urls):
                Button { NSWorkspace.shared.activateFileViewerSelecting(urls) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.plain).help("Show in Finder")
            case .failed: EmptyView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .done(let urls) = job.state { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .running: Image(systemName: "gearshape.2").foregroundStyle(WheelView.accent).symbolEffect(.rotate, options: .repeating)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
