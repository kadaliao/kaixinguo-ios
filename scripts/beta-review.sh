#!/bin/sh
# beta-review.sh hands a build to the external testing group 「朋友」, which
# anyone can join through its public link. It waits until App Store Connect
# has processed the build, copies the version's section of CHANGELOG.md into
# What to Test, adds the build to the group and submits it to TestFlight App
# Review. Testers get the build once Apple approves it, usually within a day.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/beta-review.sh [<version> <build number>]
#
# testflight.sh runs it after every upload. Without arguments it takes the
# version and build number in project.yml. Running it again is safe: it
# refreshes What to Test and skips what is already done.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
asc=$here/scripts/asc.sh
app=6831169843
group_name=朋友

version=${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$here/project.yml")}
number=${2:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' "$here/project.yml")}

# Replies go into a variable before jq reads them, so that a failed request
# stops the script: in a pipe, only jq's status would count.
groups=$("$asc" GET "/v1/apps/$app/betaGroups?fields[betaGroups]=name,publicLink&limit=200")
group=$(printf %s "$groups" | jq -c --arg n "$group_name" '.data[] | select(.attributes.name == $n)')
[ -n "$group" ] || { echo "App Store Connect 里没有测试组「${group_name}」，见 docs/releasing.md" >&2; exit 1; }
group_id=$(printf %s "$group" | jq -r .id)
link=$(printf %s "$group" | jq -r .attributes.publicLink)

# A build shows up in the API a minute or so after the upload, then takes 5
# to 15 minutes to process. A failed request counts as not processed yet.
printf '[1/3] 等 App Store Connect 处理 %s (%s)' "$version" "$number"
tries=0
while :; do
	build=$("$asc" GET "/v1/builds?filter[app]=$app&filter[version]=$number&filter[preReleaseVersion.version]=$version&fields[builds]=processingState" 2>/dev/null |
		jq -c '.data[0] // empty')
	state=$(printf %s "$build" | jq -r '.attributes.processingState // empty')
	case $state in
	VALID) break ;;
	FAILED | INVALID) echo; echo "构建处理失败（${state}），到 App Store Connect 看看原因" >&2; exit 1 ;;
	esac
	tries=$((tries + 1))
	[ $tries -le 120 ] || { echo; echo "等了一小时还没处理完，过会儿再运行 scripts/beta-review.sh $version $number" >&2; exit 1; }
	printf .
	sleep 30
done
echo
build_id=$(printf %s "$build" | jq -r .id)

echo "[2/3] 填写测试内容，加进「${group_name}」"
# The version's section of CHANGELOG.md, with "### 新增" turned into "新增：".
notes=$(awk -v v="[$version]" '
	/^## / { on = index($0, v) == 4; next }
	on && /^### / { sub(/^### +/, ""); print $0 "："; next }
	on { print }' "$here/CHANGELOG.md" | awk 'NF { for (; blank > 0; blank--) print ""; print; started = 1; next } started { blank++ }')
[ -n "$notes" ] || notes="看看推荐、搜索和播放是否正常。"
notes="$notes

遇到问题可以在 TestFlight 里截屏反馈。"
locs=$("$asc" GET "/v1/builds/$build_id/betaBuildLocalizations")
loc=$(printf %s "$locs" | jq -r '.data[] | select(.attributes.locale == "zh-Hans") | .id')
if [ -n "$loc" ]; then
	"$asc" PATCH "/v1/betaBuildLocalizations/$loc" "$(jq -nc --arg id "$loc" --arg t "$notes" \
		'{data: {type: "betaBuildLocalizations", id: $id, attributes: {whatsNew: $t}}}')" >/dev/null
else
	"$asc" POST /v1/betaBuildLocalizations "$(jq -nc --arg id "$build_id" --arg t "$notes" \
		'{data: {type: "betaBuildLocalizations", attributes: {locale: "zh-Hans", whatsNew: $t}, relationships: {build: {data: {type: "builds", id: $id}}}}}')" >/dev/null
fi
"$asc" POST "/v1/betaGroups/$group_id/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$build_id\"}]}" >/dev/null

echo "[3/3] 提交 TestFlight 审核"
submission=$("$asc" GET "/v1/builds/$build_id/betaAppReviewSubmission")
if [ "$(printf %s "$submission" | jq .data)" = null ]; then
	submission=$("$asc" POST /v1/betaAppReviewSubmissions \
		"{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$build_id\"}}}}}")
fi
review=$(printf %s "$submission" | jq -r .data.attributes.betaReviewState)
echo "审核状态：${review}。通过后，打开公开链接就能安装：$link"
