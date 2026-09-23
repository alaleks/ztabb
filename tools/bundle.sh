#!/bin/sh
# Assembles zig-out/ztabb.app around the installed binary and the rendered
# icon. macOS only shows an application icon for a bundle; a bare executable
# run from a shell borrows the terminal's.
set -eu

out=zig-out
app="$out/ztabb.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$out/bin/ztabb" "$app/Contents/MacOS/ztabb"
cp "$out/ztabb.icns" "$app/Contents/Resources/ztabb.icns"

# Carry SDL3 inside the bundle and point the binary at that copy. Linking the
# Homebrew path would leave an installed app broken the moment the formula is
# upgraded or removed.
sdl=$(otool -L "$app/Contents/MacOS/ztabb" | awk '/libSDL3/ {print $1; exit}')
if [ -n "$sdl" ] && [ -f "$sdl" ]; then
    cp "$sdl" "$app/Contents/Frameworks/"
    name=$(basename "$sdl")
    chmod u+w "$app/Contents/Frameworks/$name"
    install_name_tool -change "$sdl" "@executable_path/../Frameworks/$name" \
        "$app/Contents/MacOS/ztabb"
    install_name_tool -id "@executable_path/../Frameworks/$name" \
        "$app/Contents/Frameworks/$name"
fi

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

# Rewriting the load paths invalidates whatever signature the linker left, and
# on Apple Silicon an unsigned binary will not start. Ad-hoc signing is enough
# for a locally built app.
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/"*.dylib 2>/dev/null || true
codesign --force --sign - --timestamp=none "$app" 2>/dev/null || true

# A bundle whose signature never changes keeps a stale icon in the Finder
# cache; touching it is what makes the new one show up.
touch "$app"
echo "built $app"
