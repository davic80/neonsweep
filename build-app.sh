#!/bin/zsh
# Empaqueta NeonSweep como .app (build release + bundle + firma ad-hoc)
set -e
cd "$(dirname "$0")"

VERSION="0.2.0"

swift build -c release

APP=build/NeonSweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/NeonSweep "$APP/Contents/MacOS/NeonSweep"

# Recursos SPM (traducciones) e icono
if [ -d .build/release/NeonSweep_NeonSweep.bundle ]; then
    cp -R .build/release/NeonSweep_NeonSweep.bundle "$APP/Contents/Resources/"
fi
if [ -f assets/NeonSweep.icns ]; then
    cp assets/NeonSweep.icns "$APP/Contents/Resources/NeonSweep.icns"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>NeonSweep</string>
    <key>CFBundleDisplayName</key>       <string>NeonSweep</string>
    <key>CFBundleIdentifier</key>        <string>com.davidcornejo.neonsweep</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>        <string>NeonSweep</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>NeonSweep</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NeonSweep pide a Finder que vacíe la Papelera cuando tú lo confirmas.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>NeonSweep analiza tu librería para encontrar duplicados y originales enormes. Solo borra lo que tú marques, y va a "Eliminado recientemente".</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "OK -> $APP"
