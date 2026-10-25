#!/bin/bash
# 一键把 CamWindow.swift 打包成可双击运行的 CamWindow.app
# 用法：bash build.sh
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "还没有安装苹果命令行工具，先运行：xcode-select --install"
  echo "装完后再运行一次：bash build.sh"
  exit 1
fi

if [ ! -f CamWindow.swift ]; then
  echo "没有找到 CamWindow.swift，请把它和 build.sh 放在同一个文件夹"
  exit 1
fi

APP="CamWindow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "正在编译…"
swiftc -O CamWindow.swift -o "$APP/Contents/MacOS/CamWindow"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CamWindow</string>
  <key>CFBundleIdentifier</key><string>local.camwindow</string>
  <key>CFBundleName</key><string>CamWindow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>用于在悬浮窗口中显示摄像头画面</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "完成：已生成 $(pwd)/$APP"
echo "以后直接双击 CamWindow.app 即可，也可以把它拖进「应用程序」文件夹。"
open "$APP"
