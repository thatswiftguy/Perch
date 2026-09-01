#!/bin/bash
# Build, sign, notarise and staple a distributable Perch.app.
#
# Everyday development needs none of this — Xcode ad-hoc signs the app and it runs fine
# on the machine that built it. This script is only for producing a build other people
# can download without Gatekeeper refusing to open it.
#
# Prerequisites, each checked below:
#   1. A "Developer ID Application" certificate in your keychain. An "Apple Development"
#      certificate is NOT sufficient — it cannot be notarised. Create one in Xcode:
#      Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application.
#   2. Your team ID, passed as TEAM_ID or set below.
#   3. A stored notarytool credential profile:
#      xcrun notarytool store-credentials "perch-notary" \
#          --apple-id "<your-apple-id>" --team-id "<TEAM_ID>" --password "<app-specific-password>"
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-perch-notary}"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/Perch.xcarchive"

fail() { echo "error: $*" >&2; exit 1; }

echo "==> Preflight"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo
    echo "No 'Developer ID Application' certificate found. You currently have:"
    security find-identity -v -p codesigning | sed 's/^/    /'
    echo
    fail "Apple Development certificates cannot be notarised. See the header of this script."
fi
[ -n "$TEAM_ID" ] || fail "TEAM_ID is not set. Run: TEAM_ID=XXXXXXXXXX $0"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarytool profile '$NOTARY_PROFILE'. See the header of this script."

echo "==> Archiving"
rm -rf "$BUILD_DIR"
xcodebuild archive \
    -project Perch.xcodeproj -scheme Perch -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/export"

APP="$BUILD_DIR/export/Perch.app"

echo "==> Notarising (this waits for Apple, usually a few minutes)"
# Notarisation takes a zip, not a bundle. ditto preserves the signature; `zip` does not.
ditto -c -k --keepParent "$APP" "$BUILD_DIR/Perch.zip"
xcrun notarytool submit "$BUILD_DIR/Perch.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
# Staples the ticket into the bundle so it opens offline too.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

# Ship the stapled bundle, not the pre-notarisation zip.
rm -f "$BUILD_DIR/Perch.zip"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/Perch.zip"

echo
echo "Done: $BUILD_DIR/Perch.zip"
