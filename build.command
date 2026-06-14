#!/bin/bash
#
# Pulse — build it yourself.
#
# Double-click this file (or run it) to COMPILE the Pulse menu-bar app from
# source, right here on your Mac. Nothing is downloaded — swiftc turns
# Pulse.swift into Pulse.app, which then lives in your menu bar.
#
# Requirements: macOS with the Swift toolchain (Xcode or the Command Line
# Tools — `xcode-select --install`). That's it.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

APP="Pulse.app"
SRC="Pulse.swift"
BUNDLE_ID="net.amitghosh.pulse"

echo "▸ Building Pulse from $SRC …"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc not found. Install the Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

# Fresh bundle skeleton -------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Info.plist — LSUIElement keeps it out of the Dock; it's a menu-bar agent ----
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pulse for Claude by Dexter</string>
  <key>CFBundleDisplayName</key><string>Pulse for Claude by Dexter</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Pulse</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Pulse — Claude usage in your menu bar.</string>
</dict>
</plist>
PLIST

# Compile ---------------------------------------------------------------------
swiftc "$SRC" \
  -o "$APP/Contents/MacOS/Pulse" \
  -O \
  -framework AppKit -framework ServiceManagement \
  -target arm64-apple-macos13.0

# Ad-hoc codesign so macOS lets it run without quarantine fuss ----------------
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
echo "▸ Launching Pulse (look in your menu bar, top-right)…"
# Relaunch cleanly if it was already running.
pkill -x Pulse >/dev/null 2>&1 || true
open "$APP"

cat <<TIP

Done. Pulse now lives in your menu bar — a pulse glyph + your 5-hour usage %.
Click it for the full panel (session, weekly, Opus, Sonnet) with reset times.

• Move it permanently:   drag Pulse.app into /Applications
• Launch at login:       System Settings ▸ General ▸ Login Items ▸ +  (add Pulse)
• Rebuild after edits:   double-click build.command again
TIP
