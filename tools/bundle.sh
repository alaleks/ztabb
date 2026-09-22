#!/bin/sh
# Assembles zig-out/ztabb.app around the installed binary and the rendered
# icon. macOS only shows an application icon for a bundle; a bare executable
# run from a shell borrows the terminal's.
set -eu

out=zig-out
app="$out/ztabb.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/bin/ztabb" "$app/Contents/MacOS/ztabb"
cp "$out/ztabb.icns" "$app/Contents/Resources/ztabb.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>ztabb</string>
  <key>CFBundleDisplayName</key>     <string>ztabb</string>
  <key>CFBundleIdentifier</key>      <string>dev.ztabb.terminal</string>
  <key>CFBundleExecutable</key>      <string>ztabb</string>
  <key>CFBundleIconFile</key>        <string>ztabb</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>11.0</string>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# A bundle whose signature never changes keeps a stale icon in the Finder
# cache; touching it is what makes the new one show up.
touch "$app"
echo "built $app"
