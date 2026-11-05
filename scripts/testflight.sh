#!/bin/sh
# testflight.sh archives the app, signs it for the App Store and uploads it
# to App Store Connect; it shows in TestFlight once Apple has processed it,
# in 5 to 15 minutes.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/testflight.sh
#
# The App Store Connect API key is read from
# ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 (or ASC_KEY_PATH). It
# also signs: Xcode makes the certificates and profiles it needs.
#
# Every upload needs a build number above the last one: raise
# CURRENT_PROJECT_VERSION in project.yml, or pass BUILD_NUMBER=<n>.
set -eu
: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the API key issuer ID}"
key=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[ -f "$key" ] || { echo "no API key at $key" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/build/release
auth="-allowProvisioningUpdates -authenticationKeyPath $key -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
build=${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER}

(cd "$here" && xcodegen generate --quiet)
rm -rf "$out"
mkdir -p "$out"

echo "[1/3] 归档"
# shellcheck disable=SC2086 # auth and build are lists of words
xcodebuild archive -project "$here/Kaixinguo.xcodeproj" -scheme Kaixinguo -configuration Release \
	-destination 'generic/platform=iOS' -archivePath "$out/Kaixinguo.xcarchive" $auth $build -quiet

echo "[2/3] 导出"
cat >"$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>HMDAVG9B8J</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$out/Kaixinguo.xcarchive" -exportPath "$out/export" \
	-exportOptionsPlist "$out/ExportOptions.plist" $auth -quiet

echo "[3/3] 上传"
xcrun altool --upload-app -f "$out/export/Kaixinguo.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
plist=$out/Kaixinguo.xcarchive/Info.plist
echo "已上传 $(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$plist"))，处理完会出现在 TestFlight"
