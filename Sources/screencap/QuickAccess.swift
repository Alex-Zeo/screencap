import AppKit

/// Floating thumbnail shown after a capture, stacked bottom-left like CleanShot's Quick Access Overlay.
@MainActor
final class QuickAccessCenter {
    static let shared = QuickAccessCenter()
    private var panels: [QuickAccessPanel] = []
    var onEdit: ((NSImage, URL) -> Void)?

    func show(image: NSImage, fileURL: URL) {
        let panel = QuickAccessPanel(image: image, fileURL: fileURL)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panels.removeAll { $0 === panel }
            panel.orderOut(nil)
            self.layout()
        }
        panel.onEdit = { [weak self] in self?.onEdit?(image, fileURL) }
        panels.append(panel)
        layout()
        panel.orderFrontRegardless()
        panel.scheduleAutoDismiss(after: 8)
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        var y = screen.visibleFrame.minY + 16
        for panel in panels {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 16, y: y))
            y += panel.frame.height + 10
        }
    }
}

private final class QuickAccessPanel: NSPanel {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    private var dismissTimer: Timer?
    private let thumb: ThumbnailView

    init(image: NSImage, fileURL: URL) {
        let maxSide: CGFloat = 200
        let ratio = image.size.width / max(image.size.height, 1)
        let size = ratio >= 1 ? NSSize(width: maxSide, height: maxSide / ratio) : NSSize(width: maxSide * ratio, height: maxSide)
        thumb = ThumbnailView(image: image, fileURL: fileURL, frame: NSRect(origin: .zero, size: size))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = thumb
        thumb.onClose = { [weak self] in self?.onClose?() }
        thumb.onEdit = { [weak self] in
            self?.onEdit?()
            self?.onClose?()
        }
        thumb.onHover = { [weak self] hovering in
            if hovering { self?.dismissTimer?.invalidate() } else { self?.scheduleAutoDismiss(after: 4) }
        }
    }

    func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.onClose?() }
        }
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    let image: NSImage
    let fileURL: URL
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let buttons = NSStackView()
    private var mouseDownPoint: NSPoint?

    init(image: NSImage, fileURL: URL, frame: NSRect) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))

        buttons.orientation = .vertical
        buttons.spacing = 6
        buttons.isHidden = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for (title, action) in [("Copy", #selector(copyImage)), ("Edit", #selector(edit)),
                                ("Show", #selector(reveal)), ("Close", #selector(close))] {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            buttons.addArrangedSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        if !buttons.isHidden {
            NSColor.black.withAlphaComponent(0.5).setFill()
            bounds.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        buttons.isHidden = false
        needsDisplay = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        buttons.isHidden = true
        needsDisplay = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Toast.show("Copied")
    }
    @objc private func edit() { onEdit?() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    @objc private func close() { onClose?() }
}

@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 28, height: label.frame.height + 16)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: 14, y: 8)
        box.addSubview(label)
        p.contentView = box
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 40))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p?.animator().alphaValue = 0 },
                                                 completionHandler: { p?.orderOut(nil) })
        }
    }
}
