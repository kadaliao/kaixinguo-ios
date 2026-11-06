#!/bin/sh
# invite.sh invites testers by email to the external group 「朋友」:
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/invite.sh <email>...
#
# TestFlight emails them once a build has passed review. Sending someone the
# public link works too, without this script. Inviting the same address again
# resends the email.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
asc=$here/scripts/asc.sh
app=6831169843
group_name=朋友
[ $# -ge 1 ] || { echo "usage: $0 <email>..." >&2; exit 2; }

groups=$("$asc" GET "/v1/apps/$app/betaGroups?fields[betaGroups]=name&limit=200")
group_id=$(printf %s "$groups" | jq -r --arg n "$group_name" '.data[] | select(.attributes.name == $n) | .id')
[ -n "$group_id" ] || { echo "App Store Connect 里没有测试组「${group_name}」，见 docs/releasing.md" >&2; exit 1; }

for email; do
	found=$("$asc" GET "/v1/betaTesters?filter[email]=$(jq -rn --arg e "$email" '$e | @uri')&filter[apps]=$app")
	tester=$(printf %s "$found" | jq -r '.data[0].id // empty')
	if [ -z "$tester" ]; then
		"$asc" POST /v1/betaTesters "$(jq -nc --arg e "$email" --arg g "$group_id" \
			'{data: {type: "betaTesters", attributes: {email: $e}, relationships: {betaGroups: {data: [{type: "betaGroups", id: $g}]}}}}')" >/dev/null
		echo "已邀请 $email"
	else
		"$asc" POST "/v1/betaGroups/$group_id/relationships/betaTesters" "{\"data\":[{\"type\":\"betaTesters\",\"id\":\"$tester\"}]}" >/dev/null
		"$asc" POST /v1/betaTesterInvitations "$(jq -nc --arg t "$tester" --arg a "$app" \
			'{data: {type: "betaTesterInvitations", relationships: {app: {data: {type: "apps", id: $a}}, betaTester: {data: {type: "betaTesters", id: $t}}}}}')" >/dev/null
		echo "已重新邀请 $email"
	fi
done
