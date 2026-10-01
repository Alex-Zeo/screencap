import AppKit
import Foundation

/// Capture the current, authenticated page by scrolling its existing browser tab.
@MainActor
enum PageCapture {
    enum PageError: LocalizedError {
        case browser, automation, geometry, tooLarge, changed

        var errorDescription: String? {
            switch self {
            case .browser: return "Open the page in Safari or Google Chrome, then capture again."
            case .automation: return "Allow screencap to control your browser and enable Allow JavaScript from Apple Events in its developer menu."
            case .geometry: return "Keep the browser on one display, close docked developer tools, and use 100% page zoom."
            case .tooLarge: return "This page is too large to capture as one image."
            case .changed: return "The page changed during capture. Please try again."
            }
        }
    }

    private struct Metrics: Decodable {
        let x: Double, y: Double, width: Double, height: Double
        let innerWidth: Double, innerHeight: Double, outerWidth: Double, outerHeight: Double
        let screenX: Double, screenY: Double, zoom: Double
        let deviceScale: Double
    }

    private struct Browser {
        let bundle: String
        let safari: Bool
        let windowID: Int
        let tabID: Int

        init() throws {
            guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  bundle == "com.apple.Safari" || bundle.hasPrefix("com.google.Chrome") else { throw PageError.browser }
            self.bundle = bundle
            safari = bundle == "com.apple.Safari"
            let selection = safari ? """
                set w to front window
                set n to 1
                repeat with i from 1 to count of tabs of w
                    if current tab of w is tab i of w then set n to i
                end repeat
                return ((id of w) as string) & ":" & (n as string)
                """ : "return ((id of front window) as string) & \":\" & ((id of active tab of front window) as string)"
            let value = try Self.run("tell application id \"\(bundle)\"\n\(selection)\nend tell")
            let parts = value.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { throw PageError.browser }
            windowID = parts[0]
            tabID = parts[1]
        }

        func javascript(_ code: String, requireActive: Bool = true) throws -> String {
            // Quote as an AppleScript string, never interpolate page-controlled text into code.
            let quoted = "\"" + code.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            let target = safari ? "tab \(tabID) of w" : "tab id \(tabID) of w"
            let check = requireActive ? "if id of front window is not \(windowID) then error \"Window changed\"\n" +
                (safari ? "if current tab of w is not \(target) then error \"Tab changed\""
                : "if id of active tab of w is not \(tabID) then error \"Tab changed\"") : ""
            let command = safari ? "do JavaScript \(quoted) in \(target)" : "execute \(target) javascript \(quoted)"
            return try Self.run("tell application id \"\(bundle)\"\nset w to window id \(windowID)\n\(check)\nreturn \(command)\nend tell")
        }

        private static func run(_ source: String) throws -> String {
            guard let script = NSAppleScript(source: source) else { throw PageError.automation }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil, let value = result.stringValue else { throw PageError.automation }
            return value
        }
    }

    static func capture() async throws -> NSImage {
        let browser = try Browser()
        let key = "__screencap_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let setup = """
            (() => {
                const root = document.documentElement;
                window['\(key)'] = {x:scrollX, y:scrollY, url:location.href, hidden:[],
                    behavior:root.style.getPropertyValue('scroll-behavior'),
                    priority:root.style.getPropertyPriority('scroll-behavior'),
                    snap:root.style.getPropertyValue('scroll-snap-type'),
                    snapPriority:root.style.getPropertyPriority('scroll-snap-type')};
                root.style.setProperty('scroll-behavior','auto','important');
                root.style.setProperty('scroll-snap-type','none','important');
                return 'ready';
            })()
            """
        _ = try browser.javascript(setup)
        defer {
            _ = try? browser.javascript("""
                (() => {
                    const s = window['\(key)']; if (!s) return 'gone';
                    for (const [node,value,priority] of s.hidden) node.style.setProperty('visibility',value,priority);
                    window.scrollTo({left:s.x,top:s.y,behavior:'instant'});
                    const root = document.documentElement;
                    root.style.setProperty('scroll-behavior',s.behavior,s.priority);
                    root.style.setProperty('scroll-snap-type',s.snap,s.snapPriority);
                    delete window['\(key)']; return 'restored';
                })()
                """, requireActive: false)
        }
        func metrics() throws -> Metrics {
            let result = try browser.javascript("""
                (() => {
                    const s=window['\(key)']; if(!s || s.url!==location.href) return '{}';
                    const root=document.documentElement;
                    return JSON.stringify({x:scrollX,y:scrollY,width:Math.max(root.scrollWidth,document.body?.scrollWidth||0),
                        height:Math.max(root.scrollHeight,document.body?.scrollHeight||0),
                        innerWidth,innerHeight,outerWidth,outerHeight,screenX,screenY,
                        zoom:visualViewport?.scale||1,deviceScale:devicePixelRatio});
                })()
                """)
            guard let data = result.data(using: .utf8), let value = try? JSONDecoder().decode(Metrics.self, from: data) else {
                throw PageError.changed
            }
            return value
        }
        let initial = try metrics()
        let numbers = [initial.width, initial.height, initial.innerWidth, initial.innerHeight,
                       initial.outerWidth, initial.outerHeight, initial.screenX, initial.screenY]
        guard numbers.allSatisfy({ $0.isFinite }), initial.innerWidth > 0, initial.innerHeight > 0,
              initial.width > 0, initial.height > 0, abs(initial.zoom - 1) < 0.01 else { throw PageError.geometry }
        let primaryHeight = NSScreen.screens[0].frame.height
        let region = CGRect(x: initial.screenX + (initial.outerWidth - initial.innerWidth) / 2,
                            y: primaryHeight - initial.screenY - initial.outerHeight,
                            width: initial.innerWidth, height: initial.innerHeight)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }) else { throw PageError.geometry }
        let scale = screen.backingScaleFactor
        guard abs(initial.deviceScale - scale) < 0.05,
              initial.width * scale <= 80_000_000, initial.height * scale <= 80_000_000 else { throw PageError.geometry }
        let width = Int(ceil(initial.width * scale)), height = Int(ceil(initial.height * scale))
        guard width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              ceil(initial.width / initial.innerWidth) * ceil(initial.height / initial.innerHeight) <= 100 else { throw PageError.tooLarge }
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PageError.tooLarge }
        canvas.scaleBy(x: scale, y: scale)
        var top: Double = 0
        while top < initial.height {
            var left: Double = 0
            while left < initial.width {
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.bundle else { throw PageError.changed }
                _ = try browser.javascript("window.scrollTo({left:\(left),top:\(top),behavior:'instant'});'scrolled'")
                try await Task.sleep(nanoseconds: 350_000_000)
                let current = try metrics()
                guard current.width == initial.width, current.height == initial.height,
                      current.innerWidth == initial.innerWidth, current.innerHeight == initial.innerHeight,
                      current.screenX == initial.screenX, current.screenY == initial.screenY else { throw PageError.changed }
                let image = try await CaptureService.captureArea(region, on: screen)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PageError.changed }
                // At the last tile the browser clamps scrolling. Draw only the previously uncovered strip.
                let strip = CGRect(x: left, y: Double(height) / scale - min(top + initial.innerHeight, initial.height),
                                   width: min(initial.innerWidth, initial.width - left),
                                   height: min(initial.innerHeight, initial.height - top))
                canvas.saveGState()
                canvas.clip(to: strip)
                canvas.draw(cg, in: CGRect(x: current.x, y: Double(height) / scale - current.y - initial.innerHeight,
                                          width: initial.innerWidth, height: initial.innerHeight))
                canvas.restoreGState()
                if top == 0, left == 0 {
                    _ = try browser.javascript("""
                        (() => { const s=window['\(key)'];
                            for(const node of document.querySelectorAll('*')) {
                                if(['fixed','sticky'].includes(getComputedStyle(node).position)) {
                                    s.hidden.push([node,node.style.getPropertyValue('visibility'),node.style.getPropertyPriority('visibility')]);
                                    node.style.setProperty('visibility','hidden','important');
                                }
                            } return 'hidden'; })()
                        """)
                }
                left += initial.innerWidth
            }
            top += initial.innerHeight
        }
        guard let cg = canvas.makeImage() else { throw PageError.tooLarge }
        return NSImage(cgImage: cg, size: CGSize(width: initial.width, height: initial.height))
    }
}
