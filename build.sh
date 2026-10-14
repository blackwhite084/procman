#!/bin/zsh
# 编译 Procman 并安装到 ~/Applications/Procman.app
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Procman.app"
mkdir -p build

swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
    Sources/*.swift -o build/Procman

rm -rf build/AppIcon.iconset
./build/Procman --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

# 已在运行就先退出（退出不会停止服务，新版本启动后会自动接管）
pkill -x Procman && sleep 1 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Procman "$APP/Contents/MacOS/Procman"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.procman.app</string>
  <key>CFBundleName</key><string>Procman</string>
  <key>CFBundleDisplayName</key><string>Procman</string>
  <key>CFBundleExecutable</key><string>Procman</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "已安装: $APP"
