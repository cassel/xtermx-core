#!/usr/bin/env bash
# Builds the Mac app for distribution outside the App Store: signed with Developer ID,
# notarized by Apple, stapled, packed in a .dmg. (TestFlight/App Store Mac apps must be
# sandboxed, and a sandboxed terminal cannot run your shell or your agents.)
#
#   TEAM_ID=ABCDE12345 ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/AuthKey_….p8 ./Release/mac-release.sh
#
# Needs a paid Apple Developer team in Xcode and an App Store Connect API key (used for notarization).
# Optional: XTX_BUNDLE_PREFIX (default us.cassel.xtermx → Mac app us.cassel.xtermx.mac), VERSION_BUILD.
set -euo pipefail

: "${TEAM_ID:?Set TEAM_ID to the paid team ID}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key, used to notarize)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH to the .p8 file}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
prefix="${XTX_BUNDLE_PREFIX:-us.cassel.xtermx}"
build="${VERSION_BUILD:-$(date +%Y%m%d%H%M)}"
out="$repo/build/release"
archive="$out/XTermX-macOS-$build.xcarchive"
export_dir="$out/mac-$build"
auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
mkdir -p "$out"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

cd "$repo"
xcodegen generate

say "Archiving the Mac app (build $build)"
xcodebuild archive \
    -project XTermX.xcodeproj -scheme XTermX-macOS -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -skipPackagePluginValidation -allowProvisioningUpdates "${auth[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" XTX_BUNDLE_PREFIX="$prefix" CURRENT_PROJECT_VERSION="$build" CODE_SIGN_STYLE=Automatic

cat > "$out/ExportOptions-DeveloperID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

say "Signing with Developer ID"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions-DeveloperID.plist" \
    -exportPath "$export_dir" -allowProvisioningUpdates "${auth[@]}"
app="$export_dir/XTermX.app"

say "Checking microphone and camera access"
# Without these, programs in a pane (voice input, video tools) are denied silently by macOS.
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
for key in com.apple.security.device.audio-input com.apple.security.device.camera; do
    grep -q "$key" <<<"$entitlements" || { echo "Missing entitlement $key" >&2; exit 1; }
done
for key in NSMicrophoneUsageDescription NSCameraUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" >/dev/null || { echo "Missing $key in Info.plist" >&2; exit 1; }
done

say "Packing the disk image"
dmg="$out/XTermX-$build.dmg"
staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "XTermX" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging"

say "Notarizing (Apple usually answers in a few minutes)"
xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"

say "Ready: $dmg — opens on any Mac without warnings."
