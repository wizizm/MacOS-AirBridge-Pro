#!/bin/bash
set -e
WORKSPACE_DIR="/Users/tiwut/Documents/dev/wifi-bridge"
APP_DIR="${WORKSPACE_DIR}/AirBridge.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

curl -s -L "https://github.com/tiwut.png" -o /tmp/tiwut.png
mkdir -p /tmp/AppIcon.iconset
sips -z 16 16 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_16x16.png
sips -z 32 32 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_32x32.png
sips -z 64 64 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_128x128.png
sips -z 256 256 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_256x256.png
sips -z 512 512 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_512x512.png
sips -z 1024 1024 /tmp/tiwut.png --out /tmp/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns /tmp/AppIcon.iconset -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf /tmp/AppIcon.iconset /tmp/tiwut.png

cat << 'EOF' > "${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AirBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.AirBridge</string>
    <key>CFBundleName</key>
    <string>AirBridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) \
       -framework Cocoa \
       -framework SwiftUI \
       -framework CoreWLAN \
       "${WORKSPACE_DIR}/main.swift" \
       -o "${MACOS_DIR}/AirBridge"

chmod +x "${MACOS_DIR}/AirBridge"
