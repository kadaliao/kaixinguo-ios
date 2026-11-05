#!/bin/sh
# shoot.sh builds the app for a simulator, opens a link in it and takes a
# screenshot, for checking a page by eye and for the README.
#
#   scripts/shoot.sh "iPhone Air" kaixinguo://series/<id> out.png [seconds]
set -eu
device=$1 link=$2 out=$3 wait=${4:-8}
here=$(cd "$(dirname "$0")/.." && pwd)
xcodebuild -project "$here/Kaixinguo.xcodeproj" -scheme Kaixinguo -destination "platform=iOS Simulator,name=$device" \
	-derivedDataPath "$here/build/DerivedData" build -quiet
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$here/build/DerivedData/Build/Products/Debug-iphonesimulator/Kaixinguo.app"
xcrun simctl terminate "$device" com.kadaliao.kaixinguo 2>/dev/null || true
xcrun simctl launch "$device" com.kadaliao.kaixinguo -KXOpen "$link" >/dev/null
sleep "$wait"
xcrun simctl io "$device" screenshot "$out" >/dev/null
echo "$out"
