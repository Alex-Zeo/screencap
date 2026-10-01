# screencap

A CleanShot-style screenshot and screen recording tool for macOS. Native Swift, no third-party dependencies, lives in the menu bar.

## Features

| Feature | Hotkey |
|---|---|
| Capture area, then drag the thumbnail into another app | `⌘` + **left** `⇧` + `4`, once |
| Capture the entire scrolling webpage | Same shortcut, twice |
| Select an area and record it as a GIF | Same shortcut, three times |
| Capture window (hover to pick, click to capture) | `⌃⇧5` |
| Capture screen (display under the cursor) | `⌃⇧3` |
| Capture text (OCR the selected area to the clipboard) | `⌃⇧7` |
| Record area to MP4 | `⌃⇧6` |
| Record screen to MP4 | `⌃⇧8` |

- Quick Access thumbnail after each capture: copy, edit, reveal in Finder, or drag the file straight into another app.
- Keep Command and left Shift held and tap `4` once, twice, or three times. Taps must be less than 300 ms apart. Holding `4` does not count as multiple taps. One or two taps wait 300 ms for the sequence to finish; three taps open the GIF selector immediately.
- Drag to select the screenshot or GIF area. GIF recording stops when you press `⌘` + left `⇧` + `4` again, click the stop icon, or reach 30 seconds. The GIF appears as a draggable file in Quick Access. GIFs loop at up to 15 FPS with a maximum dimension of 960 pixels.
- If another screenshot app owns `⌘⇧4`, quit it or change its shortcut. Disable macOS's selection screenshot shortcut in System Settings > Keyboard > Keyboard Shortcuts > Screenshots if it conflicts. screencap reports when it cannot claim the shortcut.
- Annotation editor: arrow, rectangle, ellipse, pen, highlighter, text, pixelate. Undo, copy, save.
- Choose whether captures go to the clipboard, to disk, or both, from the menu bar icon.
- While recording, click the menu bar icon (or press the record hotkey again) to stop.
- Screenshots and recordings are saved to `~/Pictures/screencap`.

Built on ScreenCaptureKit (`SCScreenshotManager`, `SCRecordingOutput`), Vision for OCR, and Carbon hotkeys, which need no Accessibility permission.

Whole-page capture uses the existing tab in Safari or Google Chrome, including its current login session. Allow browser control when macOS asks, and enable **Allow JavaScript from Apple Events** in the browser's developer menu. Keep the window on one display at 100% zoom with docked developer tools closed. Capture restores the original scroll position and page styles. Press the capture shortcut again to cancel. Pages that resize while scrolling, exceed 80 megapixels, or need more than 100 tiles are rejected. Firefox and nested scrolling panels are not supported yet.

## Requirements

macOS 15 or later (`SCRecordingOutput` is macOS 15+). Swift 6 toolchain (Xcode 16 or the matching Command Line Tools).

## Build and run

```sh
./scripts/build.sh
open build/screencap.app
```

Grant **Screen Recording** permission when prompted (System Settings > Privacy & Security > Screen & System Audio Recording), then relaunch.

The build script uses an available Developer ID Application identity, or the identity specified by `CODESIGN_IDENTITY`. Keep the same signing identity and install path across updates so macOS privacy grants persist. Without a Developer ID identity, the script warns and falls back to ad-hoc signing. Each changed ad-hoc binary has a new designated requirement, so Screen Recording and browser-control grants may need to be renewed. Switching from an ad-hoc build to a Developer ID build also needs one fresh grant. A fixed bundle identifier alone does not preserve permissions.

If the build fails with `redefinition of module 'SwiftBridging'`, your Command Line Tools have a stale duplicate modulemap. Reinstalling the CLT fixes it permanently. To build without sudo:

```sh
CLT_MODULEMAP_WORKAROUND=1 ./scripts/build.sh
```

`Package.swift` is included so you can open the folder in Xcode. `scripts/build.sh` is the tested build path.

## Status

Early (0.1.0). Real macOS checks cover the single/double/triple shortcut, right-Shift rejection, held-key repeat suppression, screenshot and animated GIF file drops, GIF clipboard data, window picking, Chrome scrolling capture and cancellation with scroll/style restoration. Gesture sequence assertions pass. The original capture, OCR, MP4 recording and annotation save/undo paths have also been exercised.

Developer ID signing was checked against the approved Screen Recording requirement across different binaries, then verified with live captures after updating the installed app. Safari's native browser bridge is implemented; live scrolling checks were performed in Chrome.

Not yet done:

- Scrolling capture in Firefox and nested panels
- Configurable hotkeys and save location UI
- Pin-to-screen and self-timer
- Broader automated UI test coverage

## License

MIT
