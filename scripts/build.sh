#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
bundle=dist/WiFiHelper.app
mkdir -p "$bundle/Contents/MacOS" dist/bin
cp "$binary_dir/wifi" "$bundle/Contents/MacOS/WiFiHelper"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.wifi-cli.helper</string>
  <key>CFBundleName</key><string>WiFi CLI</string>
  <key>CFBundleDisplayName</key><string>WiFi CLI</string>
  <key>CFBundleExecutable</key><string>WiFiHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSLocationWhenInUseUsageDescription</key><string>WiFi CLI needs Location Services to display Wi-Fi network names and access-point identifiers. It does not request your coordinates.</string>
  <key>NSLocationUsageDescription</key><string>WiFi CLI needs Location Services to display Wi-Fi network names and access-point identifiers.</string>
</dict></plist>
PLIST
# Local development defaults to ad-hoc signing. Opt into your own stable signing
# identity with SIGN_IDENTITY; no certificates or account credentials are bundled.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier local.wifi-cli.helper \
  --options runtime --entitlements Resources/WiFiHelper.entitlements \
  --timestamp=none "$bundle"
# Keep the executable inside its signed bundle so Info.plist/resource validation
# remains valid. Both instances have the same designated requirement.
ln -sfn ../WiFiHelper.app/Contents/MacOS/WiFiHelper dist/bin/wifi
codesign --verify --strict "$bundle"
codesign --verify --strict dist/bin/wifi
printf 'Built %s/dist/bin/wifi\n' "$PWD"
