#!/bin/bash
set -e

# Define directories dynamically relative to the script location
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$WORKSPACE_DIR/build"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
SVG_ICON="$WORKSPACE_DIR/Sources/App icon.svg"

# Extract version and define DMG names dynamically
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORKSPACE_DIR/Sources/Info.plist")
VOL_NAME="Ambeat $VERSION"
DMG_NAME="Ambeat-$VERSION.dmg"

echo "=== Step 1: Converting SVG to AppIcon.icns ==="
mkdir -p "$BUILD_DIR"
mkdir -p "$ICONSET_DIR"

# Write Swift script to render SVG sizes
cat << 'EOF' > "$BUILD_DIR/render_svg.swift"
import Cocoa

guard CommandLine.arguments.count >= 3 else {
    print("Usage: render_svg <svg_path> <output_dir>")
    exit(1)
}
let svgPath = CommandLine.arguments[1]
let outputDir = CommandLine.arguments[2]

guard let image = NSImage(contentsOfFile: svgPath) else {
    print("Error: Could not load SVG from \(svgPath)")
    exit(1)
}

let sizes = [
    ("icon_16x16.png", 16.0),
    ("icon_16x16@2x.png", 32.0),
    ("icon_32x32.png", 32.0),
    ("icon_32x32@2x.png", 64.0),
    ("icon_128x128.png", 128.0),
    ("icon_128x128@2x.png", 256.0),
    ("icon_256x256.png", 256.0),
    ("icon_256x256@2x.png", 512.0),
    ("icon_512x512.png", 512.0),
    ("icon_512x512@2x.png", 1024.0)
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

for (name, size) in sizes {
    let targetSize = NSSize(width: size, height: size)
    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: targetSize).fill()
    image.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
    newImage.unlockFocus()
    
    guard let tiffData = newImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Failed to convert image representation for \(name)")
        continue
    }
    
    let outputPath = (outputDir as NSString).appendingPathComponent(name)
    do {
        try pngData.write(to: URL(fileURLWithPath: outputPath))
    } catch {
        print("Failed to write \(name): \(error)")
    }
}
print("Successfully generated all icon PNGs.")
EOF

# Execute Swift script
swift "$BUILD_DIR/render_svg.swift" "$SVG_ICON" "$ICONSET_DIR"

# Generate .icns using iconutil
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/AppIcon.icns"
echo "Generated AppIcon.icns successfully."

echo "=== Step 2: Copying AppIcon.icns to sources ==="
# Save a copy in Sources/ for completeness
cp "$BUILD_DIR/AppIcon.icns" "$WORKSPACE_DIR/Sources/AppIcon.icns"

echo "=== Step 3: Compiling Application using SwiftPM ==="
swift build -c release

# Find the binary and bundle path
BINARY_PATH=""
BUNDLE_PATH=""
for path in .build/arm64-apple-macosx/release .build/release; do
    if [ -f "$path/Ambeat" ]; then
        BINARY_PATH="$path/Ambeat"
        BUNDLE_PATH="$path/Ambeat_Ambeat.bundle"
        break
    fi
done

if [ -z "$BINARY_PATH" ]; then
    echo "Error: Built binary not found."
    exit 1
fi

echo "=== Step 4: Assembling Ambeat.app Bundle ==="
BUILT_APP="$BUILD_DIR/Ambeat.app"
rm -rf "$BUILT_APP"
mkdir -p "$BUILT_APP/Contents/MacOS"
mkdir -p "$BUILT_APP/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$BUILT_APP/Contents/MacOS/Ambeat"

# Copy resource bundle if it exists
if [ -d "$BUNDLE_PATH" ]; then
    cp -R "$BUNDLE_PATH" "$BUILT_APP/Contents/Resources/"
fi

# Copy AppIcon
cp "$BUILD_DIR/AppIcon.icns" "$BUILT_APP/Contents/Resources/AppIcon.icns"

# Copy pre-configured Info.plist
cp "$BUILD_DIR/Info.plist" "$BUILT_APP/Contents/Info.plist"

# Code-sign the assembled app bundle
echo "Ad-hoc signing the application bundle..."
codesign --force --sign - "$BUILT_APP"

echo "=== Step 5: Packaging application into DMG ==="
# Clean up any old DMG
rm -f "$WORKSPACE_DIR/Ambeat-*.dmg"
rm -f "$BUILD_DIR/temp.dmg"

# Ensure any previous volume is detached
hdiutil detach "/Volumes/$VOL_NAME" 2>/dev/null || true

# Create a temporary writable DMG (size 100M is plenty)
hdiutil create -size 100m -fs HFS+ -volname "$VOL_NAME" -ov "$BUILD_DIR/temp.dmg"

# Mount temporary DMG to default /Volumes/$VOL_NAME
hdiutil attach "$BUILD_DIR/temp.dmg" -readwrite

# Copy App and create Applications link
cp -R "$BUILT_APP" "/Volumes/$VOL_NAME/"
ln -s /Applications "/Volumes/$VOL_NAME/Applications"

# Set volume icon
cp "$BUILD_DIR/AppIcon.icns" "/Volumes/$VOL_NAME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL_NAME"

# Configure layout using AppleScript
echo "Arranging Finder window layout..."
# Let Finder process the volume mounts
sleep 3

osascript -e "
tell application \"Finder\"
    tell disk \"$VOL_NAME\"
        open
        set the current view of container window to icon view
        set the statusbar visible of container window to false
        set the toolbar visible of container window to false
        set the bounds of container window to {100, 100, 600, 400}
        set the position of item \"Ambeat.app\" to {130, 150}
        set the position of item \"Applications\" to {370, 150}
        set icon size of icon view options of container window to 96
        close
    end tell
end tell
" || echo "Warning: Finder layout configuration failed (this is non-critical)."

sleep 2

# Unmount
hdiutil detach "/Volumes/$VOL_NAME"

# Convert to read-only compressed DMG
hdiutil convert "$BUILD_DIR/temp.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORKSPACE_DIR/$DMG_NAME"

echo "=== Step 6: Cleaning up ==="
rm -f "$BUILD_DIR/temp.dmg"
rm -rf "$ICONSET_DIR"
rm -f "$BUILD_DIR/render_svg.swift"

echo "=== DMG Package Created Successfully! ==="
ls -lh "$WORKSPACE_DIR/$DMG_NAME"
