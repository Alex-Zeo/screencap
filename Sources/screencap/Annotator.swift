import AppKit
import CoreImage

enum AnnotationTool: Int, CaseIterable {
    case arrow, rectangle, ellipse, pen, highlight, text, pixelate

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "square.grid.3x3.fill"
        }
    }
}

private struct Annotation {
    var tool: AnnotationTool
    var color: NSColor
    var points: [CGPoint] // image-point coordinates, top-left origin
    var text: String = ""

    var bounds: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
    }
}

@MainActor
final class AnnotatorWindowController: NSObject, NSWindowDelegate {
    private static var open: [AnnotatorWindowController] = []

    private let window: NSWindow
    private let canvas: CanvasView
    private let fileURL: URL

    static func present(image: NSImage, fileURL: URL) {
        let c = AnnotatorWindowController(image: image, fileURL: fileURL)
        open.append(c)
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(image: NSImage, fileURL: URL) {
        self.fileURL = fileURL
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let fit = min(1, (screenSize.width * 0.85) / image.size.width, (screenSize.height * 0.8) / image.size.height)
        let canvasSize = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        canvas = CanvasView(image: image, frame: NSRect(origin: .zero, size: canvasSize))

        let barHeight: CGFloat = 40
        let root = NSView(frame: NSRect(x: 0, y: 0, width: max(canvasSize.width, 520), height: canvasSize.height + barHeight))
        window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Annotate: \(fileURL.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.center()

        canvas.frame.origin = NSPoint(x: (root.frame.width - canvasSize.width) / 2, y: 0)
        canvas.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        root.addSubview(canvas)
        root.addSubview(makeToolbar(width: root.frame.width, height: barHeight))
    }

    private func makeToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.frame = NSRect(x: 0, y: window.contentView!.frame.height - height, width: width, height: height)
        bar.autoresizingMask = [.width, .minYMargin]

        let tools = NSSegmentedControl(images: AnnotationTool.allCases.map {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: "\($0)") ?? NSImage()
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        bar.addArrangedSubview(tools)

        let color = NSColorWell(style: .minimal)
        color.color = .systemRed
        color.target = self
        color.action = #selector(colorChanged(_:))
        color.widthAnchor.constraint(equalToConstant: 32).isActive = true
        bar.addArrangedSubview(color)

        bar.addArrangedSubview(NSView()) // spacer
        for (title, action) in [("Undo", #selector(undo)), ("Copy", #selector(copyImage)), ("Save", #selector(save))] {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            bar.addArrangedSubview(b)
        }
        return bar
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = AnnotationTool(rawValue: sender.selectedSegment) ?? .arrow
    }
    @objc private func colorChanged(_ sender: NSColorWell) { canvas.color = sender.color }
    @objc private func undo() { canvas.undo() }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([canvas.renderFinal()])
        Toast.show("Copied")
    }

    @objc private func save() {
        guard let png = canvas.renderFinal().pngData else {
            Toast.show("Could not encode PNG")
            return
        }
        do {
            try png.write(to: fileURL, options: .atomic)
            Toast.show("Saved \(fileURL.lastPathComponent)")
        } catch {
            Toast.show("Save failed: \(error.localizedDescription)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

private final class CanvasView: NSView, NSTextFieldDelegate {
    let image: NSImage
    var tool: AnnotationTool = .arrow
    var color: NSColor = .systemRed

    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var pixelateCache: [String: CGImage] = [:]
    private let ciContext = CIContext()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// View points per image point.
    private var scale: CGFloat { bounds.width / image.size.width }

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func undo() {
        commitText()
        if !annotations.isEmpty { annotations.removeLast() }
        needsDisplay = true
    }

    // MARK: Input

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        let p = imagePoint(event)
        if tool == .text {
            beginText(at: p)
            return
        }
        current = Annotation(tool: tool, color: color, points: [p, p])
    }

    override func mouseDragged(with event: NSEvent) {
        guard var a = current else { return }
        let p = imagePoint(event)
        if a.tool == .pen || a.tool == .highlight {
            a.points.append(p)
        } else {
            a.points[a.points.count - 1] = p
        }
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = current else { return }
        current = nil
        let tooSmall = a.tool != .pen && a.tool != .highlight && a.bounds.width < 3 && a.bounds.height < 3
        if !tooSmall { annotations.append(a) }
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers else { return false }
        if key == "z" {
            undo()
            return true
        }
        return false
    }

    // MARK: Text tool

    private func beginText(at p: CGPoint) {
        let field = NSTextField(frame: NSRect(x: p.x * scale, y: p.y * scale, width: 200, height: 26))
        field.font = .systemFont(ofSize: 18 * scale, weight: .semibold)
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(textCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = p
    }

    @objc private func textCommitted() { commitText() }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let value = field.stringValue
        field.removeFromSuperview()
        if !value.isEmpty {
            annotations.append(Annotation(tool: .text, color: field.textColor ?? color, points: [textOrigin, textOrigin], text: value))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        draw(into: cg, includePreview: true)
        cg.restoreGState()
    }

    /// Shared by on-screen drawing and export; `cg` must already be in flipped image-point space.
    private func draw(into cg: CGContext, includePreview: Bool) {
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for a in annotations { render(a, in: cg) }
        if includePreview, let c = current { render(c, in: cg) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func render(_ a: Annotation, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(a.color.cgColor)
        cg.setFillColor(a.color.cgColor)
        cg.setLineWidth(4)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let r = a.bounds
        switch a.tool {
        case .rectangle:
            cg.stroke(r)
        case .ellipse:
            cg.strokeEllipse(in: r)
        case .pen:
            cg.addLines(between: a.points)
            cg.strokePath()
        case .highlight:
            cg.setStrokeColor(a.color.withAlphaComponent(0.4).cgColor)
            cg.setLineWidth(18)
            cg.setLineCap(.butt)
            cg.addLines(between: a.points)
            cg.strokePath()
        case .arrow:
            drawArrow(from: a.points[0], to: a.points[a.points.count - 1], in: cg)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: a.color]
            (a.text as NSString).draw(at: a.points[0], withAttributes: attrs)
        case .pixelate:
            if let px = pixelated(rect: r) { cg.draw(px, in: r) }
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, in cg: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 16
        cg.move(to: start)
        cg.addLine(to: end)
        cg.strokePath()
        cg.move(to: end)
        cg.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
        cg.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        cg.closePath()
        cg.fillPath()
    }

    private func pixelated(rect: CGRect) -> CGImage? {
        guard rect.width > 1, rect.height > 1,
              let base = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let key = "\(rect)"
        if let hit = pixelateCache[key] { return hit }
        let sx = CGFloat(base.width) / image.size.width
        let sy = CGFloat(base.height) / image.size.height
        // CIImage uses a bottom-left origin; the annotation rect is top-left.
        let crop = CGRect(x: rect.minX * sx, y: CGFloat(base.height) - rect.maxY * sy, width: rect.width * sx, height: rect.height * sy)
        let ci = CIImage(cgImage: base).cropped(to: crop)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ci, forKey: kCIInputImageKey)
        filter?.setValue(max(8, min(crop.width, crop.height) / 8), forKey: kCIInputScaleKey)
        guard let out = filter?.outputImage?.cropped(to: crop),
              let result = ciContext.createCGImage(out, from: crop) else { return nil }
        pixelateCache[key] = result
        return result
    }

    // MARK: Export

    func renderFinal() -> NSImage {
        commitText()
        guard let base = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cg = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        cg.scaleBy(x: CGFloat(base.width) / image.size.width, y: CGFloat(base.height) / image.size.height)
        // Flip into top-left image-point space.
        cg.translateBy(x: 0, y: image.size.height)
        cg.scaleBy(x: 1, y: -1)
        draw(into: cg, includePreview: false)
        guard let out = cg.makeImage() else { return image }
        return NSImage(cgImage: out, size: image.size)
    }
}
