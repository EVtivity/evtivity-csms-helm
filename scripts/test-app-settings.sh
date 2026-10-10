#!/usr/bin/env bash
# Render tests for templates/app-settings-configmap.yaml: every AI app setting
# the chart maps renders into settings.json with the value set in values, an
# empty value keeps the dashboard value (renders ""), a values file without the
# blocks (helm upgrade --reuse-values from an older release) still renders, and
# out-of-range or unknown values fail the render.
#
# Usage: scripts/test-app-settings.sh   (from anywhere; needs helm 3 and node)
# Exit: 0 when every check passes, 1 otherwise. Prints one line per failure and
# a summary line.
set -uo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

S=(--set secrets.databaseUrl=postgres://u:p@db:5432/evtivity
  --set secrets.redisUrls.api=redis://api:p@r:6379 --set secrets.redisUrls.ocpp=redis://ocpp:p@r:6379
  --set secrets.redisUrls.ocpi=redis://ocpi:p@r:6379 --set secrets.redisUrls.worker=redis://worker:p@r:6379
  --set secrets.redisUrls.css=redis://css:p@r:6379
  --set secrets.jwtSecret=placeholderplaceholderplaceholder12
  --set secrets.settingsEncryptionKey=placeholderplaceholderplaceholder12
  --set initialAdmin.password=PlaceholderPassw0rd!)

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

# render <out file> <helm args...>: writes settings.json of the configmap.
render() {
  local out="$1"
  shift
  helm template t "$CHART" "${S[@]}" --show-only templates/app-settings-configmap.yaml "$@" > "$TMP/render.yaml" 2> "$TMP/render.err" || return 1
  node -e '
    const fs = require("fs");
    const doc = fs.readFileSync(process.argv[1], "utf8");
    const body = doc.split("settings.json: |\n")[1].replace(/^    /gm, "");
    fs.writeFileSync(process.argv[2], JSON.stringify(JSON.parse(body)));
  ' "$TMP/render.yaml" "$out"
}

# expect_json <settings file> <expected JSON object>: every key equals.
expect_json() {
  node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const want = JSON.parse(process.argv[2]);
    let n = 0;
    for (const [k, v] of Object.entries(want)) {
      if (!(k in got)) { console.log("missing " + k); n++; continue; }
      if (JSON.stringify(got[k]) !== JSON.stringify(v)) {
        console.log(k + ": got " + JSON.stringify(got[k]) + ", want " + JSON.stringify(v)); n++;
      }
    }
    process.exit(n ? 1 : 0);
  ' "$1" "$2"
}

# expect_fail <label> <message part> <helm args...>
expect_fail() {
  local label="$1" msg="$2"
  shift 2
  if render "$TMP/x.json" "$@"; then
    bad "$label: rendered, want a failure"
  elif grep -qF -- "$msg" "$TMP/render.err"; then
    ok
  else
    bad "$label: failed for another reason: $(head -1 "$TMP/render.err")"
  fi
}

NEW_KEYS='["opsAi.enabled","opsAi.provider","opsAi.model","opsAi.effort","opsAi.systemPrompt",
"aiInsights.station.enabled","aiInsights.session.enabled","aiInsights.authorization.enabled",
"aiInsights.debounceSeconds","aiInsights.cooldownMinutes","aiInsights.siteIncidentThreshold",
"aiInsights.maxPerSitePerDay","aiInsights.primaryLanguage","aiInsights.retentionDays",
"aiWorkers.networkSummary.enabled","aiWorkers.stuckSessions.enabled","aiWorkers.stuckSessions.idleMinutes",
"aiWorkers.stuckSessions.useModel","aiWorkers.tariffAnomalies.enabled","aiWorkers.proposalTtlHours",
"ai.mcp.enabled","ai.mcp.rateLimitPerMinute","ai.mcp.dailyCallsPerKey","ai.mcp.proposalTtlMinutes",
"ai.mcp.allowedOrigins","ai.budget.companyMonthlyTokens","ai.budget.siteMonthlyTokens",
"ai.budget.siteDailyTokens","ai.budget.warnPercent"]'
EMPTY=$(node -e 'const k = JSON.parse(process.argv[1]); console.log(JSON.stringify(Object.fromEntries(k.map((x) => [x, ""]))))' "$NEW_KEYS")

# 1. Defaults: every new key renders empty (keep the dashboard value).
if render "$TMP/default.json"; then
  if r=$(expect_json "$TMP/default.json" "$EMPTY"); then ok; else bad "defaults: $r"; fi
else
  bad "defaults: render failed: $(head -1 "$TMP/render.err")"
fi

# 2. Every new key maps to its setting.
cat > "$TMP/set.yaml" <<'EOF'
appSettings:
  opsAi:
    enabled: true
    provider: openai
    model: gpt-test
    effort: medium
    systemPrompt: "Be brief."
  aiInsights:
    station: { enabled: false }
    session: { enabled: true }
    authorization: { enabled: false }
    debounceSeconds: 0
    cooldownMinutes: 10080
    siteIncidentThreshold: 2
    maxPerSitePerDay: 10000
    primaryLanguage: zh-TW
    retentionDays: 3650
  aiWorkers:
    networkSummary: { enabled: true }
    stuckSessions: { enabled: true, idleMinutes: 15, useModel: true }
    tariffAnomalies: { enabled: false }
    proposalTtlHours: 168
  ai:
    mcp:
      enabled: true
      rateLimitPerMinute: 10000
      dailyCallsPerKey: 10000000
      proposalTtlMinutes: 5
      allowedOrigins: ["https://agent.example.com", "http://localhost:3000", "https://[::1]:8443"]
    budget:
      companyMonthlyTokens: 1000000000000
      siteMonthlyTokens: 0
      siteDailyTokens: 10000000000
      warnPercent: 100
EOF
WANT='{"opsAi.enabled":true,"opsAi.provider":"openai","opsAi.model":"gpt-test","opsAi.effort":"medium",
"opsAi.systemPrompt":"Be brief.","aiInsights.station.enabled":false,"aiInsights.session.enabled":true,
"aiInsights.authorization.enabled":false,"aiInsights.debounceSeconds":0,"aiInsights.cooldownMinutes":10080,
"aiInsights.siteIncidentThreshold":2,"aiInsights.maxPerSitePerDay":10000,"aiInsights.primaryLanguage":"zh-TW",
"aiInsights.retentionDays":3650,"aiWorkers.networkSummary.enabled":true,"aiWorkers.stuckSessions.enabled":true,
"aiWorkers.stuckSessions.idleMinutes":15,"aiWorkers.stuckSessions.useModel":true,
"aiWorkers.tariffAnomalies.enabled":false,"aiWorkers.proposalTtlHours":168,"ai.mcp.enabled":true,
"ai.mcp.rateLimitPerMinute":10000,"ai.mcp.dailyCallsPerKey":10000000,"ai.mcp.proposalTtlMinutes":5,
"ai.mcp.allowedOrigins":["https://agent.example.com","http://localhost:3000","https://[::1]:8443"],
"ai.budget.companyMonthlyTokens":1000000000000,"ai.budget.siteMonthlyTokens":0,
"ai.budget.siteDailyTokens":10000000000,"ai.budget.warnPercent":100}'
if node -e 'const a = Object.keys(JSON.parse(process.argv[1])).sort(), b = JSON.parse(process.argv[2]).sort(); process.exit(JSON.stringify(a) === JSON.stringify(b) ? 0 : 1)' "$WANT" "$NEW_KEYS"; then ok; else bad "test data: WANT does not cover every new key"; fi
if render "$TMP/set.json" -f "$TMP/set.yaml"; then
  if r=$(expect_json "$TMP/set.json" "$WANT"); then ok; else bad "set values: $r"; fi
else
  bad "set values: render failed: $(head -1 "$TMP/render.err")"
fi

# 3. --set strings and an empty origin list.
if render "$TMP/strings.json" --set appSettings.opsAi.enabled=false --set appSettings.ai.budget.warnPercent=1 \
  --set-json 'appSettings.ai.mcp.allowedOrigins=[]'; then
  if r=$(expect_json "$TMP/strings.json" '{"opsAi.enabled":false,"ai.budget.warnPercent":1,"ai.mcp.allowedOrigins":[]}'); then ok; else bad "--set values: $r"; fi
else
  bad "--set values: render failed: $(head -1 "$TMP/render.err")"
fi

# 4. Values without the new blocks (--reuse-values from an older release).
if render "$TMP/old.json" --set appSettings.opsAi=null --set appSettings.aiInsights=null \
  --set appSettings.aiWorkers=null --set appSettings.ai.mcp=null; then
  if r=$(expect_json "$TMP/old.json" "$EMPTY"); then ok; else bad "missing blocks: $r"; fi
else
  bad "missing blocks: render failed: $(head -1 "$TMP/render.err")"
fi

# 5. Refused values.
expect_fail "opsAi.provider" 'appSettings.opsAi.provider "azure" is not supported' --set appSettings.opsAi.provider=azure
expect_fail "opsAi.effort" 'appSettings.opsAi.effort "max" is not supported' --set appSettings.opsAi.effort=max
expect_fail "opsAi.enabled" 'appSettings.opsAi.enabled "yes" is not supported' --set-string appSettings.opsAi.enabled=yes
expect_fail "aiInsights.station.enabled" 'appSettings.aiInsights.station.enabled "1" is not supported' --set appSettings.aiInsights.station.enabled=1
expect_fail "aiInsights.primaryLanguage" 'appSettings.aiInsights.primaryLanguage "fr" is not supported' --set appSettings.aiInsights.primaryLanguage=fr
expect_fail "aiWorkers.stuckSessions.useModel" 'appSettings.aiWorkers.stuckSessions.useModel "on" is not supported' --set appSettings.aiWorkers.stuckSessions.useModel=on
expect_fail "ai.mcp.enabled" 'appSettings.ai.mcp.enabled "maybe" is not supported' --set appSettings.ai.mcp.enabled=maybe
for v in aiInsights.debounceSeconds=3601 aiInsights.cooldownMinutes=0 aiInsights.siteIncidentThreshold=1 \
  aiInsights.maxPerSitePerDay=10001 aiInsights.retentionDays=0 aiWorkers.stuckSessions.idleMinutes=14 \
  aiWorkers.proposalTtlHours=169 ai.mcp.rateLimitPerMinute=0 ai.mcp.dailyCallsPerKey=10000001 \
  ai.mcp.proposalTtlMinutes=4 ai.budget.companyMonthlyTokens=1000000000001 ai.budget.siteMonthlyTokens=-1 \
  ai.budget.siteDailyTokens=10000000001 ai.budget.warnPercent=0 ai.budget.warnPercent=1.5; do
  expect_fail "$v" "appSettings.${v%%=*} \"${v#*=}\" is not supported" --set "appSettings.$v"
done
for o in https://agent.example.com/ https://agent.example.com/path ftp://agent.example.com agent.example.com \
  'https://agent.example.com?x=1' https://; do
  expect_fail "origin $o" 'appSettings.ai.mcp.allowedOrigins entry' --set-json "appSettings.ai.mcp.allowedOrigins=[\"$o\"]"
done
expect_fail "origins not a list" 'appSettings.ai.mcp.allowedOrigins must be a list' --set appSettings.ai.mcp.allowedOrigins=https://agent.example.com
MANY=$(node -e 'console.log(JSON.stringify(Array.from({ length: 51 }, (_, i) => "https://a" + i + ".example.com")))')
expect_fail "51 origins" 'more than 50 entries' --set-json "appSettings.ai.mcp.allowedOrigins=$MANY"

echo "app settings render tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
