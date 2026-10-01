#!/usr/bin/env bash
# Builds build/screencap.app with plain swiftc, so it works with only the Command Line Tools installed.
#
# CLT_MODULEMAP_WORKAROUND=1 hides a stale duplicate SwiftBridging modulemap that some Command Line Tools
# installs ship after an in-place update. Symptom: "redefinition of module 'SwiftBridging'" on `import Foundation`.
# The permanent fix is reinstalling the CLT; this flag avoids needing sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/screencap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

extra=()
if [[ "${CLT_MODULEMAP_WORKAROUND:-0}" == "1" ]]; then
  overlay_dir=$(mktemp -d)
  : > "$overlay_dir/empty.modulemap"
  cat > "$overlay_dir/overlay.yaml" <<YAML
{"version": 0, "case-sensitive": "false", "roots": [{"name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "type": "file", "external-contents": "$overlay_dir/empty.modulemap"}]}
YAML
  extra=(-vfsoverlay "$overlay_dir/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$overlay_dir/overlay.yaml")
fi

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  ${extra[@]+"${extra[@]}"} \
  Sources/screencap/*.swift -o "$APP/Contents/MacOS/screencap"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# TCC stores the designated requirement. Ad-hoc requirements contain a changing
# cdhash; a Developer ID requirement keeps the same app/team identity across builds.
signing_identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2; exit}')
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity=-
  echo "warning: no Developer ID identity found; ad-hoc rebuilds require fresh privacy grants" >&2
fi
codesign --force --sign "$signing_identity" --timestamp=none --identifier com.alexzeo.screencap "$APP"
echo "built $APP"
