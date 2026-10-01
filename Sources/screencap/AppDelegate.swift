import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let selection = SelectionController()
    private let recorder = Recorder()
    private var menu: NSMenu!
    private var copyItem: NSMenuItem!
    private var saveItem: NSMenuItem!
    private var gifOutput: URL?
    private var gifLimit: Task<Void, Never>?
    private var isExportingGIF = false
    private var pageTask: Task<Void, Never>?
    private lazy var captureGesture = CaptureGesture { [weak self] action in
        guard let self else { return }
        switch action {
        case .area: self.captureArea()
        case .page: self.capturePage()
        case .gif: self.recordAreaGIF()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildStatusMenu()
        registerHotKeys()
        ensureScreenRecordingAccess()

        QuickAccessCenter.shared.onEdit = { image, url in AnnotatorWindowController.present(image: image, fileURL: url) }
        recorder.onFinish = { [weak self] url in self?.recordingFinished(url) }
        recorder.onError = { [weak self] error in
            self?.gifLimit?.cancel()
            self?.gifLimit = nil
            self?.gifOutput = nil
            self?.setRecordingUI(false)
            Toast.show("Recording failed: \(error.localizedDescription)")
        }
    }

    // MARK: Menu

    private func buildStatusMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "screencap")
        menu = NSMenu()
        addItem("Capture Area", key: "⌘⇧4 · 1 tap", #selector(captureArea))
        addItem("Capture Whole Page", key: "⌘⇧4 · 2 taps", #selector(capturePage))
        addItem("Capture Window", key: "⌃⇧5", #selector(captureWindow))
        addItem("Capture Screen", key: "⌃⇧3", #selector(captureScreen))
        addItem("Capture Text (OCR)", key: "⌃⇧7", #selector(captureText))
        menu.addItem(.separator())
        addItem("Record Area", key: "⌃⇧6", #selector(recordArea))
        addItem("Record Screen", key: "⌃⇧8", #selector(recordScreen))
        addItem("Record Area as GIF", key: "⌘⇧4 · 3 taps", #selector(recordAreaGIF))
        menu.addItem(.separator())
        copyItem = addItem("Copy to Clipboard", #selector(toggleCopy))
        saveItem = addItem("Save to Disk", #selector(toggleSave))
        addItem("Open Screenshots Folder", #selector(openFolder))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit screencap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        refreshToggles()
    }

    @discardableResult
    private func addItem(_ title: String, key hint: String? = nil, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: hint.map { "\(title)    \($0)" } ?? title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func refreshToggles() {
        copyItem.state = Settings.copyToClipboard ? .on : .off
        saveItem.state = Settings.saveToDisk ? .on : .off
    }

    /// An accessory app has no main menu by default, which leaves Cmd+C/V/A dead in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func registerHotKeys() {
        let mods = controlKey | shiftKey
        let keys = HotKeys.shared
        if !keys.register(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, requireLeftShift: true,
                          handler: { [weak self] in self?.captureShortcut() }) {
            Toast.show("⌘⇧4 is used by another app. Change its shortcut or quit it.")
        }
        keys.register(keyCode: kVK_ANSI_3, modifiers: mods) { [weak self] in self?.captureScreen() }
        keys.register(keyCode: kVK_ANSI_4, modifiers: mods) { [weak self] in self?.captureArea() }
        keys.register(keyCode: kVK_ANSI_5, modifiers: mods) { [weak self] in self?.captureWindow() }
        keys.register(keyCode: kVK_ANSI_6, modifiers: mods) { [weak self] in self?.recordArea() }
        keys.register(keyCode: kVK_ANSI_7, modifiers: mods) { [weak self] in self?.captureText() }
        keys.register(keyCode: kVK_ANSI_8, modifiers: mods) { [weak self] in self?.recordScreen() }
    }

    private func ensureScreenRecordingAccess() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Screenshot actions

    private func captureShortcut() {
        if let pageTask {
            pageTask.cancel()
        } else if recorder.isRecording {
            captureGesture.cancel()
            stopRecording()
        } else if recorder.isBusy || isExportingGIF {
            Toast.show("Finishing the recording")
        } else {
            captureGesture.tap()
        }
    }

    @objc private func capturePage() {
        guard pageTask == nil, !recorder.isBusy, !isExportingGIF else { return }
        pageTask = Task { @MainActor in
            defer { pageTask = nil }
            do { deliver(try await PageCapture.capture()) }
            catch is CancellationError { Toast.show("Page capture cancelled") }
            catch { report(error) }
        }
    }

    @objc private func captureArea() {
        pickArea { [weak self] rect, screen in
            let image = try await CaptureService.captureArea(rect, on: screen)
            self?.deliver(image)
        }
    }

    @objc private func captureWindow() {
        Task {
            do {
                let windows = CaptureService.pickableWindows(try await CaptureService.content())
                selection.begin(mode: .window, windows: windows) { [weak self] sel in
                    guard case .window(let window)? = sel else { return }
                    self?.afterOverlay {
                        self?.deliver(try await CaptureService.captureWindow(window))
                    }
                }
            } catch { report(error) }
        }
    }

    @objc private func captureScreen() {
        let screen = screenUnderCursor()
        Task {
            do { deliver(try await CaptureService.captureScreen(screen)) } catch { report(error) }
        }
    }

    @objc private func captureText() {
        pickArea { [weak self] rect, screen in
            let image = try await CaptureService.captureArea(rect, on: screen)
            do {
                let text = try await OCR.recognize(image)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("Copied \(text.count) characters")
            } catch is OCR.NoTextFound {
                Toast.show("No text found")
            } catch {
                self?.report(error)
            }
        }
    }

    private func pickArea(_ work: @escaping @MainActor (CGRect, NSScreen) async throws -> Void) {
        selection.begin(mode: .area, windows: []) { [weak self] sel in
            guard case .area(let rect, let screen)? = sel else { return }
            self?.afterOverlay { try await work(rect, screen) }
        }
    }

    /// The overlay must be fully off screen before capture, or its dimming lands in the image.
    private func afterOverlay(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try await work()
            } catch { report(error) }
        }
    }

    private func deliver(_ image: NSImage) {
        if Settings.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        do {
            let dir = Settings.outputDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Settings.timestampedName(prefix: "Screenshot", ext: "png"))
            guard let png = image.pngData else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url, options: .atomic)
            QuickAccessCenter.shared.show(image: image, fileURL: url)
        } catch { report(error) }
    }

    // MARK: Recording

    @objc private func recordArea() {
        if recorder.isRecording { return stopRecording() }
        pickArea { [weak self] rect, screen in
            let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.height - (rect.maxY - screen.frame.minY),
                               width: rect.width, height: rect.height)
            try await self?.startRecording(screen: screen, sourceRect: local)
        }
    }

    @objc private func recordAreaGIF() {
        if recorder.isRecording { return stopRecording() }
        guard !recorder.isBusy, !isExportingGIF else { return }
        pickArea { [weak self] rect, screen in
            let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.height - (rect.maxY - screen.frame.minY),
                               width: rect.width, height: rect.height)
            try await self?.startRecording(screen: screen, sourceRect: local, gif: true)
        }
    }

    @objc private func recordScreen() {
        if recorder.isRecording { return stopRecording() }
        let screen = screenUnderCursor()
        Task {
            do { try await startRecording(screen: screen, sourceRect: nil) } catch { report(error) }
        }
    }

    private func startRecording(screen: NSScreen, sourceRect: CGRect?, gif: Bool = false) async throws {
        guard !recorder.isBusy, !isExportingGIF else { return }
        let dir = Settings.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = gif ? FileManager.default.temporaryDirectory.appendingPathComponent("screencap-\(UUID().uuidString).mp4")
                      : dir.appendingPathComponent(Settings.timestampedName(prefix: "Recording", ext: "mp4"))
        gifOutput = gif ? dir.appendingPathComponent(Settings.timestampedName(prefix: "Recording", ext: "gif")) : nil
        do { try await recorder.start(screen: screen, sourceRect: sourceRect, to: url) }
        catch { gifOutput = nil; throw error }
        setRecordingUI(true)
        if gif {
            gifLimit = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                self?.stopRecording()
            }
        }
    }

    private func recordingFinished(_ video: URL) {
        gifLimit?.cancel()
        gifLimit = nil
        setRecordingUI(false)
        guard let output = gifOutput else {
            Toast.show("Saved \(video.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([video])
            return
        }
        gifOutput = nil
        isExportingGIF = true
        Toast.show("Creating GIF")
        Task { @MainActor in
            defer { isExportingGIF = false }
            do {
                let image = try await GIFExporter.export(video, to: output)
                try? FileManager.default.removeItem(at: video)
                QuickAccessCenter.shared.show(image: image, fileURL: output, animated: true)
                Toast.show("Saved \(output.lastPathComponent)")
            } catch {
                Toast.show("GIF export failed. The video is available in Finder.")
                NSWorkspace.shared.activateFileViewerSelecting([video])
                FileHandle.standardError.write(Data("GIF export failed: \(error)\n".utf8))
            }
        }
    }

    @objc private func stopRecording() {
        Task { await recorder.stop() }
    }

    /// While recording, a click on the menu bar icon stops instead of opening the menu.
    private func setRecordingUI(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            statusItem.menu = nil
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.contentTintColor = .systemRed
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "screencap")
            button.contentTintColor = nil
            button.action = nil
            statusItem.menu = menu
        }
    }

    // MARK: Settings actions

    @objc private func toggleCopy() {
        Settings.copyToClipboard.toggle()
        refreshToggles()
    }

    @objc private func toggleSave() {
        Settings.saveToDisk.toggle()
        refreshToggles()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Settings.saveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.saveDirectory)
    }

    // MARK: Helpers

    private func screenUnderCursor() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("screencap error: \(error)\n".utf8))
        if !CGPreflightScreenCaptureAccess() {
            Toast.show("Screen Recording permission needed")
            CGRequestScreenCaptureAccess()
        } else {
            Toast.show("Capture failed: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshToggles() }
}
