import AppKit
import ScreenCaptureKit

enum Selection {
    case area(CGRect, NSScreen)
    case window(SCWindow)
}

enum SelectionMode {
    case area
    case window
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct PickableWindow {
    let window: SCWindow
    let frame: CGRect // AppKit global coordinates
}

@MainActor
final class SelectionController {
    private var overlays: [OverlayWindow] = []
    private var completion: ((Selection?) -> Void)?

    func begin(mode: SelectionMode, windows: [SCWindow], completion: @escaping (Selection?) -> Void) {
        finish(nil)
        self.completion = completion
        let pickable = windows.map { PickableWindow(window: $0, frame: CaptureService.appKitFrame(of: $0)) }
        for screen in NSScreen.screens {
            let win = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.acceptsMouseMovedEvents = true
            win.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen, windows: pickable)
            view.onFinish = { [weak self] selection in self?.finish(selection) }
            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            overlays.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ selection: Selection?) {
        guard !overlays.isEmpty || completion != nil else { return }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        let done = completion
        completion = nil
        done?(selection)
    }
}

private final class SelectionView: NSView {
    let mode: SelectionMode
    let screen: NSScreen
    let windows: [PickableWindow]
    var onFinish: ((Selection?) -> Void)?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hovered: PickableWindow?
    private var cursor: NSPoint?

    init(frame: NSRect, mode: SelectionMode, screen: NSScreen, windows: [PickableWindow]) {
        self.mode = mode
        self.screen = screen
        self.windows = windows
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selectionRect: NSRect? {
        switch mode {
        case .area:
            guard let a = dragStart, let b = dragCurrent else { return nil }
            return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .window:
            guard let h = hovered else { return nil }
            return NSRect(x: h.frame.minX - screen.frame.minX, y: h.frame.minY - screen.frame.minY,
                          width: h.frame.width, height: h.frame.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        dim.setFill()
        if let rect = selectionRect {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: rect))
            path.windingRule = .evenOdd
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.stroke()
            drawLabel(for: rect)
        } else {
            bounds.fill()
        }
    }

    private func drawLabel(for rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pill = NSRect(x: rect.midX - size.width / 2 - 6, y: max(rect.minY - size.height - 10, 4),
                          width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    private func globalPoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let p = globalPoint(event)
        hovered = windows.first { $0.frame.contains(p) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .area {
            dragStart = convert(event.locationInWindow, from: nil)
            dragCurrent = dragStart
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .area:
            guard let rect = selectionRect, rect.width > 3, rect.height > 3 else {
                onFinish?(nil)
                return
            }
            let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            onFinish?(.area(global, screen))
        case .window:
            if let h = hovered { onFinish?(.window(h.window)) } else { onFinish?(nil) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Escape
    }
}
