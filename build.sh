#!/bin/zsh
# Builds build/Idea Board.app.  ./build.sh --install also copies it to /Applications.
set -euo pipefail
cd "${0:A:h}"

APP="build/Idea Board.app"
VERSION="1.1"
BUILD="5"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

# App icon (regenerated only when missing)
if [[ ! -f Resources/AppIcon.icns ]]; then
  tmp=build/icon && rm -rf $tmp && mkdir -p $tmp/AppIcon.iconset
  swiftc -O tools/make_icon.swift -o $tmp/make_icon
  $tmp/make_icon $tmp/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s $tmp/icon_1024.png --out $tmp/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) $tmp/icon_1024.png --out $tmp/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $tmp/AppIcon.iconset -o Resources/AppIcon.icns
fi

swiftc -O -target arm64-apple-macos13 Sources/*.swift -o build/IdeaBoard-arm64
swiftc -O -target x86_64-apple-macos13 Sources/*.swift -o build/IdeaBoard-x86_64
lipo -create build/IdeaBoard-arm64 build/IdeaBoard-x86_64 -output "$APP/Contents/MacOS/Idea Board"
rm build/IdeaBoard-arm64 build/IdeaBoard-x86_64

cp Resources/web/index.html "$APP/Contents/Resources/web/"
mkdir -p docs && cp Resources/web/index.html docs/index.html   # GitHub Pages copy
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Idea Board</string>
  <key>CFBundleDisplayName</key><string>Idea Board</string>
  <key>CFBundleExecutable</key><string>Idea Board</string>
  <key>CFBundleIdentifier</key><string>com.lemonspitz.ideaboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 @lemonspitz · github.com/lemonspitz</string>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>com.lemonspitz.ideaboard.board</string>
    <key>UTTypeDescription</key><string>Idea Board</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>ideaboard</string></array>
    </dict>
  </dict></array>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.lemonspitz.ideaboard.join</string>
    <key>CFBundleURLSchemes</key><array><string>ideaboard</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Idea Board</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>com.lemonspitz.ideaboard.board</string></array>
  </dict></array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Idea Board.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Idea Board.app"
fi
