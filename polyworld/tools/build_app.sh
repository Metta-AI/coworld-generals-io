#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project"
nim c -d:release -o:out/generals src/generals.nim

bundle="$project/out/Polyworld Generals.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp out/generals "$bundle/Contents/MacOS/generals.new"
mv -f "$bundle/Contents/MacOS/generals.new" "$bundle/Contents/MacOS/generals"
cp -R assets "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>generals</string>
  <key>CFBundleIdentifier</key><string>local.polyworld.generals</string>
  <key>CFBundleName</key><string>Polyworld Generals</string>
  <key>CFBundleDisplayName</key><string>Polyworld Generals</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
echo "Built $bundle"
