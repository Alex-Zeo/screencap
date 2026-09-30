# screencap

A CleanShot-style screenshot and screen recording tool for macOS. Native Swift, no third-party dependencies, lives in the menu bar.

## Features

| Feature | Hotkey |
|---|---|
| Capture area | `⌃⇧4` |
| Capture window (hover to pick, click to capture) | `⌃⇧5` |
| Capture screen (display under the cursor) | `⌃⇧3` |
| Capture text (OCR the selected area to the clipboard) | `⌃⇧7` |
| Record area to MP4 | `⌃⇧6` |
| Record screen to MP4 | `⌃⇧8` |

- Quick Access thumbnail after each capture: copy, edit, reveal in Finder, or drag the file straight into another app.
- Annotation editor: arrow, rectangle, ellipse, pen, highlighter, text, pixelate. Undo, copy, save.
- Choose whether captures go to the clipboard, to disk, or both, from the menu bar icon.
- While recording, click the menu bar icon (or press the record hotkey again) to stop.
- Screenshots and recordings are saved to `~/Pictures/screencap`.

Built on ScreenCaptureKit (`SCScreenshotManager`, `SCRecordingOutput`), Vision for OCR, and Carbon hotkeys, which need no Accessibility permission.

## Requirements

macOS 15 or later (`SCRecordingOutput` is macOS 15+). Swift 6 toolchain (Xcode 16 or the matching Command Line Tools).

## Build and run

```sh
./scripts/build.sh
open build/screencap.app
```

Grant **Screen Recording** permission when prompted (System Settings > Privacy & Security > Screen & System Audio Recording), then relaunch.

If the build fails with `redefinition of module 'SwiftBridging'`, your Command Line Tools have a stale duplicate modulemap. Reinstalling the CLT fixes it permanently. To build without sudo:

```sh
CLT_MODULEMAP_WORKAROUND=1 ./scripts/build.sh
```

`Package.swift` is included so you can open the folder in Xcode. `scripts/build.sh` is the tested build path.

## Status

Early (0.1.0). Builds and launches. Not yet done:

- Scrolling capture
- GIF export
- Configurable hotkeys and save location UI
- Pin-to-screen and self-timer
- Automated tests

## License

MIT
