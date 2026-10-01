import AppKit
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case noPermission

    var description: String {
        switch self {
        case .noDisplay: return "No display matches the selected region"
        case .noPermission: return "Screen Recording permission is missing. Enable it in System Settings > Privacy & Security."
        }
    }
}

@MainActor
enum CaptureService {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Windows a user can pick, front to back, excluding this app and desktop chrome.
    static func pickableWindows(_ content: SCShareableContent) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let frontToBack = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let positions = Dictionary(uniqueKeysWithValues: frontToBack.enumerated().compactMap { index, info -> (CGWindowID, Int)? in
            guard let id = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return (id, index)
        })
        return content.windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 40
                && $0.owningApplication?.processID != me
        }.sorted { positions[$0.windowID, default: Int.max] < positions[$1.windowID, default: Int.max] }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// `rect` is in AppKit global coordinates (origin bottom-left of the primary screen).
    static func captureArea(_ rect: CGRect, on screen: NSScreen) async throws -> NSImage {
        let content = try await content()
        guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let local = localRect(rect, on: screen)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width * screen.backingScaleFactor)
        config.height = Int(local.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try await snapshot(filter: excludingSelf(display: display, content: content), config: config, points: local.size)
    }

    static func captureScreen(_ screen: NSScreen) async throws -> NSImage {
        let content = try await content()
        guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try await snapshot(filter: excludingSelf(display: display, content: content), config: config, points: screen.frame.size)
    }

    static func captureWindow(_ window: SCWindow) async throws -> NSImage {
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame(of: window)) })?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await snapshot(filter: filter, config: config, points: window.frame.size)
    }

    /// SCWindow frames use a top-left origin; AppKit uses bottom-left of the primary screen.
    static func appKitFrame(of window: SCWindow) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        let f = window.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    private static func localRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX,
               y: screen.frame.height - (rect.maxY - screen.frame.minY),
               width: rect.width, height: rect.height)
    }

    private static func excludingSelf(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        return SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
    }

    private static func snapshot(filter: SCContentFilter, config: SCStreamConfiguration, points: CGSize) async throws -> NSImage {
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: cg, size: points)
    }
}
