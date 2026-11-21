#!/usr/bin/env bash
# Publish a project's pages under https://tomasi.studio/<prefix>/.
#
#   scripts/publish-site.sh <site> <prefix> [dir]
#
# With <dir>, deploys it as the bunny site <site> first. The directory must hold
# a <prefix>/ folder at its root (request paths are passed through unchanged).
# Without <dir>, only re-syncs the route, e.g. after
# `bunny sites deployments publish --previous --force --site <site>`.
#
# The route is an "Origin Storage" edge rule on the tomasi-studio pull zone
# pointing at <site>'s live deploy. It needs a negative OrderIndex to win over
# the catch-all rule `bunny sites` manages there, and must be updated after
# every deploy or rollback of <site>, which is what this script does.
#
# Needs the bunny CLI (>= 0.22) logged in, or BUNNYNET_API_KEY set, and jq.
# This file is shared verbatim between projects; keep the copies in sync.
set -euo pipefail

site=${1:?usage: publish-site.sh <site> <prefix> [dir]}
prefix=${2:?usage: publish-site.sh <site> <prefix> [dir]}
dir=${3:-}

MAIN_PULL_ZONE=6712374 # tomasi-studio
HOST=https://tomasi.studio

if [ -n "$dir" ]; then
    [ -d "$dir/$prefix" ] || { echo "error: $dir/$prefix/ is missing" >&2; exit 1; }
    bunny sites deploy "$dir" --site "$site" --no-link
fi

pull_zone=$(bunny sites show "$site" -o json | jq -er .pullZoneId)
serve=$(bunny api GET "/pullzone/$pull_zone" -o json |
    jq -ec '.EdgeRules[] | select(.Description == "bunny sites: serve the published deploy")')
rules=$(bunny api GET "/pullzone/$MAIN_PULL_ZONE" -o json | jq -c .EdgeRules)

# Upsert an edge rule on the main pull zone, matched by its Description. An
# existing rule keeps its Guid and OrderIndex. A new one gets the next free
# negative OrderIndex: bunny requires them to be unique, and the route must sort
# before the `bunny sites` rules, which all sit at 0.
upsert() {
    local rule=$1
    rule=$(jq -c --argjson rules "$rules" '
        . as $r
        | ($rules | map(select(.Description == $r.Description)) | first) as $old
        | if $old then $r + {Guid: $old.Guid, OrderIndex: $old.OrderIndex}
          else $r + {OrderIndex: (([$rules[].OrderIndex, 0] | min) - 1)} end' <<<"$rule")
    bunny api POST "/pullzone/$MAIN_PULL_ZONE/edgerules/addOrUpdate" --body "$rule" >/dev/null
    rules=$(jq -c --argjson r "$rule" 'map(select(.Description != $r.Description)) + [$r]' <<<"$rules")
}

upsert "$(jq -nc --arg p "$prefix" --argjson s "$serve" '{
    Description: "route: \($p)", Enabled: true,
    ActionType: 17,
    ActionParameter1: $s.ActionParameter1,
    ActionParameter2: $s.ActionParameter2,
    ActionParameter3: $s.ActionParameter3,
    TriggerMatchingType: 0,
    Triggers: [{Type: 0, PatternMatchingType: 0, PatternMatches: ["*/\($p)/*"]}]
}')"

upsert "$(jq -nc --arg p "$prefix" --arg h "$HOST" '{
    Description: "route: \($p) trailing slash", Enabled: true,
    ActionType: 1, ActionParameter1: "\($h)/\($p)/", ActionParameter2: "301",
    TriggerMatchingType: 0,
    Triggers: [{Type: 0, PatternMatchingType: 0, PatternMatches: ["*/\($p)"]}]
}')"

# Purge the whole zone: a wildcard URL purge can leave pages cached, and the
# zone caches for 30 days.
bunny api POST "/pullzone/$MAIN_PULL_ZONE/purgeCache" >/dev/null

echo "$HOST/$prefix/ -> $site $(jq -r .ActionParameter3 <<<"$serve")"
