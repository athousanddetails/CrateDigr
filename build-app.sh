#!/bin/bash
set -e

APP_NAME="CrateDigr"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building release binary..."
swift build --arch arm64 -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy executable
cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"

# Copy resource bundle (SPM generates this)
cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$RESOURCES/" 2>/dev/null || true

# Copy app icon
cp "CrateDigr/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns" 2>/dev/null || true

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CrateDigr</string>
    <key>CFBundleIdentifier</key>
    <string>com.gustavolima.CrateDigr</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Crate Digr</string>
    <key>CFBundleDisplayName</key>
    <string>Crate Digr</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.36</string>
    <key>CFBundleVersion</key>
    <string>2.36</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign
codesign --force --sign - "$MACOS/$APP_NAME"

echo ""
echo "App bundle created at: $APP_BUNDLE"

# Copy app to project root
rm -rf "$APP_NAME.app"
cp -R "$APP_BUNDLE" "$APP_NAME.app"
echo "Copied to: $APP_NAME.app"
echo "To run: open $APP_NAME.app"
