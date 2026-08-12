#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="${SCRIPT_DIR}"
APP_DIR="${WORKSPACE_DIR}/AirBridge.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

ARCH="$(uname -m)"
DEPLOY_TARGET="15.0"
MACOS_TARGET="${ARCH}-apple-macos${DEPLOY_TARGET}"

ICON_SRC="/tmp/tiwut.png"
if curl -fsSL "https://github.com/tiwut.png" -o "${ICON_SRC}"; then
  mkdir -p /tmp/AppIcon.iconset
  sips -z 16 16 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_16x16.png >/dev/null
  sips -z 32 32 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_16x16@2x.png >/dev/null
  sips -z 32 32 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_32x32.png >/dev/null
  sips -z 64 64 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_32x32@2x.png >/dev/null
  sips -z 128 128 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_128x128.png >/dev/null
  sips -z 256 256 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_128x128@2x.png >/dev/null
  sips -z 256 256 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_256x256.png >/dev/null
  sips -z 512 512 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_256x256@2x.png >/dev/null
  sips -z 512 512 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_512x512.png >/dev/null
  sips -z 1024 1024 "${ICON_SRC}" --out /tmp/AppIcon.iconset/icon_512x512@2x.png >/dev/null
  iconutil -c icns /tmp/AppIcon.iconset -o "${RESOURCES_DIR}/AppIcon.icns"
  rm -rf /tmp/AppIcon.iconset "${ICON_SRC}"
else
  echo "warning: icon download failed; keeping existing AppIcon.icns if present" >&2
fi

cat << EOF > "${APP_DIR}/Contents/Info.plist"
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
    <string>${DEPLOY_TARGET}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
       -target "${MACOS_TARGET}" \
       -framework Cocoa \
       -framework SwiftUI \
       -framework CoreWLAN \
       "${WORKSPACE_DIR}/L10n.swift" \
       "${WORKSPACE_DIR}/PhyModeLabel.swift" \
       "${WORKSPACE_DIR}/IfconfigParser.swift" \
       "${WORKSPACE_DIR}/InternetSharingConfig.swift" \
       "${WORKSPACE_DIR}/main.swift" \
       -o "${MACOS_DIR}/AirBridge"

chmod +x "${MACOS_DIR}/AirBridge"

# Ad-hoc sign the whole bundle, then strip quarantine so Finder/Gatekeeper
# does not report "AirBridge.app is damaged" after copy/download.
codesign --force --deep --sign - "${APP_DIR}"
xattr -cr "${APP_DIR}"

echo "Built ${MACOS_DIR}/AirBridge for ${MACOS_TARGET}"
