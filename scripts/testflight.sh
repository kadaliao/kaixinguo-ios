#!/bin/sh
# testflight.sh archives the app, signs it for the App Store and uploads it
# to App Store Connect. Internal testers can install it once Apple has
# processed it, in 5 to 15 minutes; then beta-review.sh submits it to review
# for the public link.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/testflight.sh
#
# The App Store Connect API key is read from
# ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 (or ASC_KEY_PATH). It
# also signs: Xcode makes the certificates and profiles it needs.
#
# Every upload needs a build number above the last one: raise
# CURRENT_PROJECT_VERSION in project.yml, or pass BUILD_NUMBER=<n>.
#
# PLATFORM=tvOS uploads the Apple TV app instead of the iPhone and iPad one.
set -eu
: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the API key issuer ID}"
key=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[ -f "$key" ] || { echo "no API key at $key" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/build/release
unsigned=
case ${PLATFORM:=iOS} in
iOS) scheme=Kaixinguo altool_type=ios ;;
tvOS)
	scheme=KaixinguoTV altool_type=appletvos
	# Signing the archive takes a development profile, and that takes an
	# Apple TV registered to the team. Without one, the archive goes
	# unsigned and the export signs it for the App Store, which needs none.
	unsigned=CODE_SIGNING_ALLOWED=NO
	;;
*) echo "PLATFORM is iOS or tvOS" >&2; exit 2 ;;
esac
export PLATFORM
auth="-allowProvisioningUpdates -authenticationKeyPath $key -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
build=${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER}

(cd "$here" && xcodegen generate --quiet)
rm -rf "$out"
mkdir -p "$out"

echo "[1/3] 归档"
# shellcheck disable=SC2086 # auth and build are lists of words
xcodebuild archive -project "$here/Kaixinguo.xcodeproj" -scheme "$scheme" -configuration Release \
	-destination "generic/platform=$PLATFORM" -archivePath "$out/$scheme.xcarchive" $auth $build $unsigned -quiet

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
xcodebuild -exportArchive -archivePath "$out/$scheme.xcarchive" -exportPath "$out/export" \
	-exportOptionsPlist "$out/ExportOptions.plist" $auth -quiet

echo "[3/3] 上传"
xcrun altool --upload-app -f "$out/export/$scheme.ipa" -t "$altool_type" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
plist=$out/$scheme.xcarchive/Info.plist
version=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$plist")
number=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$plist")
echo "已上传 $version ($number)，内部测试组处理完就能装"

echo
"$here/scripts/beta-review.sh" "$version" "$number"
