#!/bin/bash
# release.sh — archive + export + upload Slapp to TestFlight, headless.
# One-time prerequisite (human step, Apple requires web login):
#   App Store Connect → Apps → + → New App:
#     Name: Slapp   Bundle: com.snail3d.slapp   SKU: slapp001
# After that exists, this script does everything else.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
IOS="$HERE/../ios"
TEAM="9V8U7PCW58"
KEY="ZZM3GSQ7RD"
ISSUER="$(cat ~/.appstoreconnect/issuer)"

echo "── archive ──"
xcodebuild -project "$IOS/Slapp.xcodeproj" -scheme Slapp \
  -configuration Release -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=$TEAM archive -archivePath /tmp/Slapp.xcarchive | tail -1

echo "── export ──"
cat > /tmp/exportOptions.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>provisioningProfiles</key>
  <dict><key>com.snail3d.slapp</key><string>Slapp iOS App Store</string></dict>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF
rm -rf /tmp/slapp-export
xcodebuild -exportArchive -archivePath /tmp/Slapp.xcarchive \
  -exportOptionsPlist /tmp/exportOptions.plist -exportPath /tmp/slapp-export | tail -1

echo "── upload to TestFlight ──"
xcrun altool --upload-app -f /tmp/slapp-export/Slapp.ipa \
  --apiKey $KEY --apiIssuer "$ISSUER" && echo "uploaded ✓ — watch it process on App Store Connect (TestFlight, ~15 min)"
