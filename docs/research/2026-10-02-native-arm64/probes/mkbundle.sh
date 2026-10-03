#!/bin/sh
# Throwaway: wrap the probe in a bundle signed with the granted entitlement. Usage: mkbundle.sh <profile> "<signing identity>"
set -eu
PROFILE=$1; IDENTITY=$2; APP=Probe.app; ID=net.authspot.macneutron.wine
security cms -D -i "$PROFILE" > profile.plist
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' profile.plist)
echo "profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' profile.plist), team $TEAM"
/usr/libexec/PlistBuddy -c 'Print :Entitlements' profile.plist
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp probe $APP/Contents/MacOS/probe
cp "$PROFILE" $APP/Contents/embedded.provisionprofile
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$ID</string><key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>Probe</string><key>LSMinimumSystemVersion</key><string>26.6</string></dict></plist>
P
cat > ent.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$TEAM.$ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>com.apple.developer.cross-architecture-support</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
P
codesign -f -s "$IDENTITY" --options runtime --entitlements ent.plist $APP
codesign -d --entitlements - $APP 2>/dev/null | head -40
