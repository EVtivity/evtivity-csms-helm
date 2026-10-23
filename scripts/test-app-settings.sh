#!/usr/bin/env bash
# Render tests for the AI app settings: every AI app setting the chart maps
# renders into settings.json with the value set in values, an empty value keeps
# the dashboard value (renders ""), a values file without the blocks (helm
# upgrade --reuse-values from an older release) still renders, and
# out-of-range or unknown values fail the render (TC-AI-C-09). The removed
# per-surface API keys and sampling values fail the render, and the
# per-provider API keys map to their encrypted settings in the sensitive
# settings Secret (TC-AI-C-03).
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
"aiInsights.maxPerSitePerDay","aiInsights.primaryLanguage",
"aiInsights.expireAfterDays",
"aiWorkers.networkSummary.enabled","aiWorkers.stuckSessions.enabled","aiWorkers.stuckSessions.idleMinutes",
"aiWorkers.stuckSessions.useModel","aiWorkers.stuckSessions.offlineEndAfterHours",
"aiWorkers.tariffAnomalies.enabled","aiWorkers.proposalTtlHours",
"ai.mcp.enabled","ai.mcp.rateLimitPerMinute","ai.mcp.dailyCallsPerKey","ai.mcp.allowWrites",
"ai.mcp.allowedOrigins","ai.budget.companyMonthlyTokens","ai.budget.siteMonthlyTokens",
"ai.budget.siteDailyTokens","ai.budget.warnPercent",
"driverAi.enabled","driverAi.provider","driverAi.model","driverAi.effort","driverAi.systemPrompt",
"driverAi.maxCasesPerDriverPerDay","driverAi.feedbackTimeoutHours","ai.budget.driverDailyTokens",
"ai.rateLimit.driverPerMinute","aiInsights.reservation.enabled"]'
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
    reservation: { enabled: false }
    debounceSeconds: 0
    cooldownMinutes: 10080
    siteIncidentThreshold: 2
    maxPerSitePerDay: 10000
    primaryLanguage: zh-TW
    expireAfterDays: 365
  aiWorkers:
    networkSummary: { enabled: true }
    stuckSessions: { enabled: true, idleMinutes: 15, useModel: true, offlineEndAfterHours: 720 }
    tariffAnomalies: { enabled: false }
    proposalTtlHours: 168
  driverAi:
    enabled: true
    provider: deepseek
    model: deepseek-test
    effort: high
    systemPrompt: "Answer briefly."
    maxCasesPerDriverPerDay: 100
    feedbackTimeoutHours: 1
  ai:
    rateLimit:
      driverPerMinute: 1000
    mcp:
      enabled: true
      rateLimitPerMinute: 10000
      dailyCallsPerKey: 10000000
      allowWrites: true
      allowedOrigins: ["https://agent.example.com", "http://localhost:3000", "https://[::1]:8443"]
    budget:
      companyMonthlyTokens: 1000000000000
      siteMonthlyTokens: 0
      siteDailyTokens: 10000000000
      warnPercent: 100
      driverDailyTokens: 0
EOF
WANT='{"opsAi.enabled":true,"opsAi.provider":"openai","opsAi.model":"gpt-test","opsAi.effort":"medium",
"opsAi.systemPrompt":"Be brief.","aiInsights.station.enabled":false,"aiInsights.session.enabled":true,
"aiInsights.authorization.enabled":false,"aiInsights.debounceSeconds":0,"aiInsights.cooldownMinutes":10080,
"aiInsights.siteIncidentThreshold":2,"aiInsights.maxPerSitePerDay":10000,"aiInsights.primaryLanguage":"zh-TW",
"aiInsights.expireAfterDays":365,"aiWorkers.networkSummary.enabled":true,"aiWorkers.stuckSessions.enabled":true,
"aiWorkers.stuckSessions.idleMinutes":15,"aiWorkers.stuckSessions.useModel":true,
"aiWorkers.stuckSessions.offlineEndAfterHours":720,
"aiWorkers.tariffAnomalies.enabled":false,"aiWorkers.proposalTtlHours":168,"ai.mcp.enabled":true,
"ai.mcp.rateLimitPerMinute":10000,"ai.mcp.dailyCallsPerKey":10000000,"ai.mcp.allowWrites":true,
"ai.mcp.allowedOrigins":["https://agent.example.com","http://localhost:3000","https://[::1]:8443"],
"ai.budget.companyMonthlyTokens":1000000000000,"ai.budget.siteMonthlyTokens":0,
"ai.budget.siteDailyTokens":10000000000,"ai.budget.warnPercent":100,
"driverAi.enabled":true,"driverAi.provider":"deepseek","driverAi.model":"deepseek-test","driverAi.effort":"high",
"driverAi.systemPrompt":"Answer briefly.","driverAi.maxCasesPerDriverPerDay":100,"driverAi.feedbackTimeoutHours":1,
"ai.budget.driverDailyTokens":0,"ai.rateLimit.driverPerMinute":1000,"aiInsights.reservation.enabled":false}'
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
  --set appSettings.aiWorkers=null --set appSettings.ai.mcp=null --set appSettings.driverAi=null; then
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
# v0.1.45: MCP writes are a switch; the proposal TTL is gone.
expect_fail "ai.mcp.allowWrites" 'appSettings.ai.mcp.allowWrites "yes" is not supported' --set-string appSettings.ai.mcp.allowWrites=yes
expect_fail "ai.mcp.proposalTtlMinutes" 'appSettings.ai.mcp.proposalTtlMinutes was removed' --set appSettings.ai.mcp.proposalTtlMinutes=30
# v0.1.45: driver support and reservation insights (TC-CFG-05).
expect_fail "driverAi.provider" 'appSettings.driverAi.provider "azure" is not supported' --set appSettings.driverAi.provider=azure
expect_fail "driverAi.effort" 'appSettings.driverAi.effort "max" is not supported' --set appSettings.driverAi.effort=max
expect_fail "driverAi.enabled" 'appSettings.driverAi.enabled "yes" is not supported' --set-string appSettings.driverAi.enabled=yes
expect_fail "aiInsights.reservation.enabled" 'appSettings.aiInsights.reservation.enabled "1" is not supported' --set appSettings.aiInsights.reservation.enabled=1
for v in driverAi.maxCasesPerDriverPerDay=0 driverAi.maxCasesPerDriverPerDay=101 driverAi.feedbackTimeoutHours=0 \
  driverAi.feedbackTimeoutHours=169 ai.budget.driverDailyTokens=-1 ai.budget.driverDailyTokens=10000000001 \
  ai.rateLimit.driverPerMinute=0 ai.rateLimit.driverPerMinute=1001; do
  expect_fail "$v" "appSettings.${v%%=*} \"${v#*=}\" is not supported" --set "appSettings.$v"
done
for v in aiInsights.debounceSeconds=3601 aiInsights.cooldownMinutes=0 aiInsights.siteIncidentThreshold=1 \
  aiInsights.maxPerSitePerDay=10001 aiWorkers.stuckSessions.idleMinutes=14 \
  aiInsights.expireAfterDays=0 aiInsights.expireAfterDays=366 \
  aiWorkers.stuckSessions.offlineEndAfterHours=0 aiWorkers.stuckSessions.offlineEndAfterHours=721 \
  aiWorkers.stuckSessions.offlineEndAfterHours=1.5 \
  aiWorkers.proposalTtlHours=169 ai.mcp.rateLimitPerMinute=0 ai.mcp.dailyCallsPerKey=10000001 \
  ai.budget.companyMonthlyTokens=1000000000001 ai.budget.siteMonthlyTokens=-1 \
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

# 6. TC-AI-C-03: the removed keys fail the render, the per-provider keys map
# to their encrypted settings in the sensitive settings Secret.
for k in chatbotAiApiKey supportAiApiKey; do
  expect_fail "sensitive.$k" "appSettings.sensitive.$k was removed" --set "appSettings.sensitive.$k=sk-old"
done
for v in chatbotAi.temperature=0.2 chatbotAi.topP=0.9 supportAi.topK=40; do
  expect_fail "$v" "appSettings.${v%%=*} was removed" --set "appSettings.$v"
done
# --reuse-values from an older release with the removed keys nulled renders.
if render "$TMP/nulled.json" --set appSettings.sensitive.chatbotAiApiKey=null \
  --set appSettings.sensitive.supportAiApiKey=null --set appSettings.chatbotAi.temperature=null; then
  ok
else
  bad "removed keys set to null: render failed: $(head -1 "$TMP/render.err")"
fi

# render_secret <out file> <helm args...>: writes sensitive-settings.json of the Secret.
render_secret() {
  local out="$1"
  shift
  helm template t "$CHART" "${S[@]}" --show-only templates/app-settings-secret.yaml "$@" > "$TMP/secret.yaml" 2> "$TMP/render.err" || return 1
  node -e '
    const fs = require("fs");
    const doc = fs.readFileSync(process.argv[1], "utf8");
    const body = doc.split("sensitive-settings.json: |\n")[1];
    fs.writeFileSync(process.argv[2], JSON.stringify(JSON.parse(body.trim())));
  ' "$TMP/secret.yaml" "$out"
}
if render_secret "$TMP/secret.json" --set appSettings.sensitive.aiAnthropicApiKey=sk-ant-test \
  --set appSettings.sensitive.aiOpenaiApiKey=sk-openai-test --set appSettings.sensitive.aiGeminiApiKey=gemini-test \
  --set appSettings.sensitive.aiDeepseekApiKey=sk-deepseek-test; then
  if r=$(expect_json "$TMP/secret.json" '{"ai.anthropic.apiKeyEnc":"sk-ant-test","ai.openai.apiKeyEnc":"sk-openai-test",
"ai.gemini.apiKeyEnc":"gemini-test","ai.deepseek.apiKeyEnc":"sk-deepseek-test"}'); then ok; else bad "provider keys: $r"; fi
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.exit(Object.keys(got).some((k) => /^(chatbotAi|supportAi)\./.test(k)) ? 1 : 0);
  ' "$TMP/secret.json"; then ok; else bad "provider keys: a per-surface key is rendered"; fi
else
  bad "provider keys: render failed: $(head -1 "$TMP/render.err")"
fi
# No provider key set: the Secret holds no AI key.
if render_secret "$TMP/secret-empty.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.exit(Object.keys(got).some((k) => k.startsWith("ai.")) ? 1 : 0);
  ' "$TMP/secret-empty.json"; then ok; else bad "no provider key: an AI key is rendered"; fi
else
  bad "no provider key: render failed: $(head -1 "$TMP/render.err")"
fi

# Guest start limits per client IP: empty keeps the dashboard value, a whole
# number from 0 to 10000 is written, anything else fails.
if render "$TMP/guest-default.json"; then
  if r=$(expect_json "$TMP/guest-default.json" '{"guest.startsPerIpPerHour":"","guest.declinesPerIpPerHour":""}'); then ok; else bad "guest limits default: $r"; fi
else
  bad "guest limits default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/guest-set.json" --set appSettings.guest.startsPerIpPerHour=0 --set appSettings.guest.declinesPerIpPerHour=10000; then
  if r=$(expect_json "$TMP/guest-set.json" '{"guest.startsPerIpPerHour":0,"guest.declinesPerIpPerHour":10000}'); then ok; else bad "guest limits set: $r"; fi
else
  bad "guest limits set: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "guest.startsPerIpPerHour" 'appSettings.guest.startsPerIpPerHour "10001" is not supported' --set appSettings.guest.startsPerIpPerHour=10001
expect_fail "guest.declinesPerIpPerHour" 'appSettings.guest.declinesPerIpPerHour "-1" is not supported' --set appSettings.guest.declinesPerIpPerHour=-1

# Invoice payment information: empty keeps the dashboard value, the IBAN and
# BIC render normalized, an IBAN with a bad checksum, a BIC of another length,
# a holder over 70 characters and a non-boolean QR switch fail.
if render "$TMP/bank-default.json"; then
  if r=$(expect_json "$TMP/bank-default.json" '{"company.bankAccountHolder":"","company.iban":"","company.bic":"","company.bankName":"","invoice.epcQrEnabled":""}'); then ok; else bad "bank details default: $r"; fi
else
  bad "bank details default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/bank-set.json" --set-string 'appSettings.company.iban=de89 3704 0044 0532 0130 00' --set appSettings.company.bic=cobadeffxxx --set-string 'appSettings.company.bankAccountHolder=Acme GmbH' --set appSettings.company.bankName=Commerzbank --set appSettings.invoice.epcQrEnabled=false; then
  if r=$(expect_json "$TMP/bank-set.json" '{"company.bankAccountHolder":"Acme GmbH","company.iban":"DE89370400440532013000","company.bic":"COBADEFFXXX","company.bankName":"Commerzbank","invoice.epcQrEnabled":false}'); then ok; else bad "bank details set: $r"; fi
else
  bad "bank details set: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/bank-gb.json" --set appSettings.company.iban=GB82WEST12345698765432 --set appSettings.invoice.epcQrEnabled=true; then
  if r=$(expect_json "$TMP/bank-gb.json" '{"company.iban":"GB82WEST12345698765432","invoice.epcQrEnabled":true}'); then ok; else bad "bank details GB: $r"; fi
else
  bad "bank details GB: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "company.iban checksum" 'appSettings.company.iban "DE89370400440532013001" is not supported' --set appSettings.company.iban=DE89370400440532013001
expect_fail "company.iban format" 'appSettings.company.iban "DE89-3704" is not supported' --set appSettings.company.iban=DE89-3704
expect_fail "company.bic" 'appSettings.company.bic "COBADEF" is not supported' --set appSettings.company.bic=COBADEF
expect_fail "company.bankAccountHolder" 'appSettings.company.bankAccountHolder is not supported' --set "appSettings.company.bankAccountHolder=$(printf 'x%.0s' $(seq 71))"
expect_fail "invoice.epcQrEnabled" 'appSettings.invoice.epcQrEnabled "yes" is not supported' --set-string appSettings.invoice.epcQrEnabled=yes

# Password policy and session lifetimes: empty keeps the dashboard value and
# the key is not rendered, a set value renders as a JSON number or boolean,
# a value out of range or of the wrong type fails.
SECURITY_KEYS='["security.password.minLength","security.password.requireUppercase","security.password.requireLowercase",
"security.password.requireNumber","security.password.requireSymbol","security.session.operatorAccessMinutes",
"security.session.operatorRefreshDays","security.session.driverAccessMinutes","security.session.driverRefreshDays"]'
if render "$TMP/security-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = JSON.parse(process.argv[2]).filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/security-default.json" "$SECURITY_KEYS"; then ok; else bad "password and session default: keys rendered"; fi
else
  bad "password and session default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/security-old.json" --set appSettings.security.password=null --set appSettings.security.session=null; then ok; else
  bad "password and session without the blocks: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/security-set.json" --set appSettings.security.password.minLength=14 \
  --set appSettings.security.password.requireUppercase=false --set appSettings.security.password.requireLowercase=true \
  --set appSettings.security.password.requireNumber=true --set appSettings.security.password.requireSymbol=true \
  --set appSettings.security.session.operatorAccessMinutes=15 --set appSettings.security.session.operatorRefreshDays=90 \
  --set appSettings.security.session.driverAccessMinutes=1440 --set appSettings.security.session.driverRefreshDays=365; then
  if r=$(expect_json "$TMP/security-set.json" '{"security.password.minLength":14,"security.password.requireUppercase":false,"security.password.requireLowercase":true,"security.password.requireNumber":true,"security.password.requireSymbol":true,"security.session.operatorAccessMinutes":15,"security.session.operatorRefreshDays":90,"security.session.driverAccessMinutes":1440,"security.session.driverRefreshDays":365}'); then ok; else bad "password and session set: $r"; fi
else
  bad "password and session set: render failed: $(head -1 "$TMP/render.err")"
fi
# A values file number (float64) and a quoted whole number both render as numbers.
printf 'appSettings:\n  security:\n    password:\n      minLength: 8\n    session:\n      operatorRefreshDays: "1"\n' > "$TMP/security-values.yaml"
if render "$TMP/security-file.json" -f "$TMP/security-values.yaml"; then
  if r=$(expect_json "$TMP/security-file.json" '{"security.password.minLength":8,"security.session.operatorRefreshDays":1}'); then ok; else bad "password and session values file: $r"; fi
else
  bad "password and session values file: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "security.password.minLength low" 'appSettings.security.password.minLength "7" is not supported' --set appSettings.security.password.minLength=7
expect_fail "security.password.minLength high" 'appSettings.security.password.minLength "65" is not supported' --set appSettings.security.password.minLength=65
expect_fail "security.password.minLength fraction" 'appSettings.security.password.minLength "12.5" is not supported' --set appSettings.security.password.minLength=12.5
expect_fail "security.password.minLength boolean" 'appSettings.security.password.minLength "true" is not supported' --set appSettings.security.password.minLength=true
expect_fail "security.password.requireSymbol string" 'appSettings.security.password.requireSymbol "yes" is not supported' --set-string appSettings.security.password.requireSymbol=yes
expect_fail "security.password.requireNumber quoted" 'appSettings.security.password.requireNumber "true" is not supported' --set-string appSettings.security.password.requireNumber=true
expect_fail "security.session.operatorAccessMinutes" 'appSettings.security.session.operatorAccessMinutes "4" is not supported' --set appSettings.security.session.operatorAccessMinutes=4
expect_fail "security.session.operatorRefreshDays" 'appSettings.security.session.operatorRefreshDays "91" is not supported' --set appSettings.security.session.operatorRefreshDays=91
expect_fail "security.session.driverAccessMinutes" 'appSettings.security.session.driverAccessMinutes "1441" is not supported' --set appSettings.security.session.driverAccessMinutes=1441
expect_fail "security.session.driverRefreshDays" 'appSettings.security.session.driverRefreshDays "0" is not supported' --set appSettings.security.session.driverRefreshDays=0
expect_fail "security.session.driverRefreshDays word" 'appSettings.security.session.driverRefreshDays "month" is not supported' --set appSettings.security.session.driverRefreshDays=month

# Required MFA: empty keeps the dashboard value and the key is not rendered, a
# set value renders as a JSON string or array, an unsupported value fails.
if render "$TMP/mfa-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = ["security.mfa.required", "security.mfa.requiredRoles"].filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/mfa-default.json"; then ok; else bad "required MFA default: keys rendered"; fi
else
  bad "required MFA default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/mfa-old.json" --set appSettings.security.mfaRequired=null --set appSettings.security.mfaRequiredRoles=null; then ok; else
  bad "required MFA without the values: render failed: $(head -1 "$TMP/render.err")"
fi
for mode in off all; do
  if render "$TMP/mfa-$mode.json" --set appSettings.security.mfaRequired=$mode; then
    if r=$(expect_json "$TMP/mfa-$mode.json" "{\"security.mfa.required\":\"$mode\"}"); then ok; else bad "required MFA $mode: $r"; fi
  else
    bad "required MFA $mode: render failed: $(head -1 "$TMP/render.err")"
  fi
done
if render "$TMP/mfa-roles.json" --set appSettings.security.mfaRequired=roles --set 'appSettings.security.mfaRequiredRoles={Admin,Site Manager}'; then
  if r=$(expect_json "$TMP/mfa-roles.json" '{"security.mfa.required":"roles","security.mfa.requiredRoles":["Admin","Site Manager"]}'); then ok; else bad "required MFA roles: $r"; fi
else
  bad "required MFA roles: render failed: $(head -1 "$TMP/render.err")"
fi
printf 'appSettings:\n  security:\n    mfaRequired: roles\n    mfaRequiredRoles:\n      - Admin\n' > "$TMP/mfa-values.yaml"
if render "$TMP/mfa-file.json" -f "$TMP/mfa-values.yaml"; then
  if r=$(expect_json "$TMP/mfa-file.json" '{"security.mfa.required":"roles","security.mfa.requiredRoles":["Admin"]}'); then ok; else bad "required MFA values file: $r"; fi
else
  bad "required MFA values file: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "security.mfaRequired unknown" 'appSettings.security.mfaRequired "some" is not supported' --set appSettings.security.mfaRequired=some
expect_fail "security.mfaRequired boolean" 'appSettings.security.mfaRequired "true" is not supported' --set appSettings.security.mfaRequired=true
expect_fail "security.mfaRequired roles without roles" 'appSettings.security.mfaRequired "roles" needs appSettings.security.mfaRequiredRoles' --set appSettings.security.mfaRequired=roles
printf 'appSettings:\n  security:\n    mfaRequired: off\n' > "$TMP/mfa-unquoted.yaml"
expect_fail "security.mfaRequired unquoted off" 'Quote the value, for example mfaRequired: "off"' -f "$TMP/mfa-unquoted.yaml"
printf 'appSettings:\n  security:\n    mfaRequired: "off"\n' > "$TMP/mfa-quoted.yaml"
if render "$TMP/mfa-quoted.json" -f "$TMP/mfa-quoted.yaml"; then
  if r=$(expect_json "$TMP/mfa-quoted.json" '{"security.mfa.required":"off"}'); then ok; else bad "required MFA quoted off: $r"; fi
else
  bad "required MFA quoted off: render failed: $(head -1 "$TMP/render.err")"
fi
# Required MFA without email and TOTP: refused only when both are set to false.
expect_fail "security.mfaRequired all without email and TOTP" 'appSettings.security.mfaRequired "all" needs appSettings.security.mfaEmailEnabled or mfaTotpEnabled' --set appSettings.security.mfaRequired=all --set appSettings.security.mfaEmailEnabled=false --set appSettings.security.mfaTotpEnabled=false
expect_fail "security.mfaRequired roles without email and TOTP" 'appSettings.security.mfaRequired "roles" needs appSettings.security.mfaEmailEnabled or mfaTotpEnabled' --set appSettings.security.mfaRequired=roles --set 'appSettings.security.mfaRequiredRoles={Admin}' --set appSettings.security.mfaEmailEnabled=false --set appSettings.security.mfaTotpEnabled=false
if render "$TMP/mfa-totp-only.json" --set appSettings.security.mfaRequired=all --set appSettings.security.mfaEmailEnabled=false; then ok; else
  bad "required MFA with TOTP only: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/mfa-email-empty.json" --set appSettings.security.mfaRequired=all --set appSettings.security.mfaEmailEnabled= --set appSettings.security.mfaTotpEnabled=false; then ok; else
  bad "required MFA with email left to the dashboard: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/mfa-off-no-methods.json" --set appSettings.security.mfaRequired=off --set appSettings.security.mfaEmailEnabled=false --set appSettings.security.mfaTotpEnabled=false; then ok; else
  bad "required MFA off without methods: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "security.mfaRequiredRoles not a list" 'appSettings.security.mfaRequiredRoles must be a list of role names' --set appSettings.security.mfaRequiredRoles=Admin
expect_fail "security.mfaRequiredRoles empty entry" 'appSettings.security.mfaRequiredRoles entry "" is not a role name' --set 'appSettings.security.mfaRequiredRoles[0]='
expect_fail "security.mfaRequiredRoles number entry" 'appSettings.security.mfaRequiredRoles entry "7" is not a role name' --set 'appSettings.security.mfaRequiredRoles={Admin,7}'
expect_fail "security.mfaRequiredRoles duplicate" 'appSettings.security.mfaRequiredRoles lists a role more than once' --set 'appSettings.security.mfaRequiredRoles={Admin,Admin}'
# The dashboard caps: at most 50 roles, each at most 100 characters.
LONG_ROLE=$(printf 'r%.0s' $(seq 1 101))
expect_fail "security.mfaRequiredRoles entry over 100 characters" 'is longer than 100 characters' --set "appSettings.security.mfaRequiredRoles={Admin,$LONG_ROLE}"
if render "$TMP/mfa-role-100.json" --set "appSettings.security.mfaRequiredRoles={${LONG_ROLE:1}}"; then ok; else
  bad "security.mfaRequiredRoles entry of 100 characters: render failed: $(head -1 "$TMP/render.err")"
fi
ROLES_51=$(seq -f 'Role%g' 1 51 | paste -sd, -)
ROLES_50=$(seq -f 'Role%g' 1 50 | paste -sd, -)
expect_fail "security.mfaRequiredRoles over 50 roles" 'lists 51 roles; the dashboard accepts at most 50' --set "appSettings.security.mfaRequiredRoles={$ROLES_51}"
if render "$TMP/mfa-roles-50.json" --set "appSettings.security.mfaRequiredRoles={$ROLES_50}"; then ok; else
  bad "security.mfaRequiredRoles of 50 roles: render failed: $(head -1 "$TMP/render.err")"
fi

# Passkeys: empty keeps the dashboard value and the key is not rendered, true
# or false renders, anything else fails, and passkey sign-in needs passkeys.
if render "$TMP/passkey-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = ["security.mfa.webauthnEnabled", "security.mfa.passkeyLoginEnabled"].filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/passkey-default.json"; then ok; else bad "passkey default: keys rendered"; fi
else
  bad "passkey default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/passkey-old.json" --set appSettings.security.mfaWebauthnEnabled=null --set appSettings.security.mfaPasskeyLoginEnabled=null; then ok; else
  bad "passkeys without the values: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/passkey-on.json" --set appSettings.security.mfaWebauthnEnabled=true --set appSettings.security.mfaPasskeyLoginEnabled=true; then
  if r=$(expect_json "$TMP/passkey-on.json" '{"security.mfa.webauthnEnabled":true,"security.mfa.passkeyLoginEnabled":true}'); then ok; else bad "passkeys on: $r"; fi
else
  bad "passkeys on: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/passkey-off.json" --set appSettings.security.mfaWebauthnEnabled=false --set appSettings.security.mfaPasskeyLoginEnabled=false; then
  if r=$(expect_json "$TMP/passkey-off.json" '{"security.mfa.webauthnEnabled":false,"security.mfa.passkeyLoginEnabled":false}'); then ok; else bad "passkeys off: $r"; fi
else
  bad "passkeys off: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "security.mfaWebauthnEnabled string" 'appSettings.security.mfaWebauthnEnabled "yes" is not supported' --set-string appSettings.security.mfaWebauthnEnabled=yes
expect_fail "security.mfaPasskeyLoginEnabled quoted" 'appSettings.security.mfaPasskeyLoginEnabled "true" is not supported' --set-string appSettings.security.mfaPasskeyLoginEnabled=true
expect_fail "security.mfaPasskeyLoginEnabled without passkeys" 'appSettings.security.mfaPasskeyLoginEnabled true needs appSettings.security.mfaWebauthnEnabled' --set appSettings.security.mfaPasskeyLoginEnabled=true --set appSettings.security.mfaWebauthnEnabled=false

# Required MFA for drivers: empty keeps the dashboard value, true or false renders,
# anything else fails, and true needs email or TOTP.
if render "$TMP/drivers-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if ("security.mfa.requireDrivers" in got) process.exit(1);
  ' "$TMP/drivers-default.json"; then ok; else bad "mfaRequireDrivers default: rendered"; fi
else
  bad "mfaRequireDrivers default: render failed: $(head -1 "$TMP/render.err")"
fi
for v in true false; do
  if render "$TMP/drivers-$v.json" --set appSettings.security.mfaRequireDrivers=$v; then
    if r=$(expect_json "$TMP/drivers-$v.json" "{\"security.mfa.requireDrivers\":$v}"); then ok; else bad "mfaRequireDrivers $v: $r"; fi
  else
    bad "mfaRequireDrivers $v: render failed: $(head -1 "$TMP/render.err")"
  fi
done
expect_fail "security.mfaRequireDrivers string" 'appSettings.security.mfaRequireDrivers "yes" is not supported' --set-string appSettings.security.mfaRequireDrivers=yes
expect_fail "security.mfaRequireDrivers without email and TOTP" 'appSettings.security.mfaRequireDrivers true needs appSettings.security.mfaEmailEnabled or mfaTotpEnabled' --set appSettings.security.mfaRequireDrivers=true --set appSettings.security.mfaEmailEnabled=false --set appSettings.security.mfaTotpEnabled=false
if render "$TMP/drivers-totp.json" --set appSettings.security.mfaRequireDrivers=true --set appSettings.security.mfaEmailEnabled=false; then ok; else
  bad "mfaRequireDrivers with TOTP only: render failed: $(head -1 "$TMP/render.err")"
fi

# WEBAUTHN_RP_ID (api.env.webauthnRpId): unset by default, the CSMS host or a
# parent domain renders, anything else fails the render.
rp_render() {
  helm template t "$CHART" "${S[@]}" --show-only templates/configmap.yaml "$@" > "$TMP/rp.yaml" 2> "$TMP/rp.err"
}
if rp_render; then
  if grep -q 'WEBAUTHN_RP_ID' "$TMP/rp.yaml"; then bad "webauthnRpId default: rendered"; else ok; fi
else
  bad "webauthnRpId default: render failed: $(head -1 "$TMP/rp.err")"
fi
for rp in evtivity.local csms.evtivity.local; do
  if rp_render --set api.env.webauthnRpId=$rp; then
    if grep -q "WEBAUTHN_RP_ID: \"$rp\"" "$TMP/rp.yaml"; then ok; else bad "webauthnRpId $rp: not rendered"; fi
  else
    bad "webauthnRpId $rp: render failed: $(head -1 "$TMP/rp.err")"
  fi
done
# Case does not matter, as for the API and the CDK config: it renders lowercased.
if rp_render --set api.env.webauthnRpId=EVtivity.Local; then
  if grep -q 'WEBAUTHN_RP_ID: "evtivity.local"' "$TMP/rp.yaml"; then ok; else bad "webauthnRpId EVtivity.Local: not lowercased"; fi
else
  bad "webauthnRpId EVtivity.Local: render failed: $(head -1 "$TMP/rp.err")"
fi
for spec in 'other.example|must be the CSMS host' 'https://evtivity.local|must be a domain name' 'evtivity.local:443|must be a domain name' 'vtivity.local|must be the CSMS host' 'local|at least two labels' '10.0.0.5|not an IP address'; do
  rp="${spec%%|*}"
  want="${spec#*|}"
  if rp_render --set "api.env.webauthnRpId=$rp"; then
    bad "webauthnRpId $rp: render passed"
  elif grep -q "$want" "$TMP/rp.err"; then ok; else
    bad "webauthnRpId $rp: wrong error: $(head -1 "$TMP/rp.err")"
  fi
done

# Browsers refuse passkeys on an IP address, so an RP ID with an IP CSMS host fails too.
if rp_render --set "gatewayAPI.routes[0].host=192.168.1.10" --set "gatewayAPI.routes[0].rules[0].path=/" \
  --set "gatewayAPI.routes[0].rules[0].service=csms" --set api.env.webauthnRpId=evtivity.local; then
  bad "webauthnRpId with an IP CSMS host: render passed"
elif grep -q 'is an IP address' "$TMP/rp.err"; then ok; else
  bad "webauthnRpId with an IP CSMS host: wrong error: $(head -1 "$TMP/rp.err")"
fi

# The passkey note of NOTES.txt (helper evtivity-csms.passkeyPortalNote) reads the
# portal host from the rendered PORTAL_URL. helm template does not render NOTES.txt,
# so a copy of the chart gets a ConfigMap that shows the helper.
NOTE_CHART="$TMP/note-chart"
cp -R "$CHART" "$NOTE_CHART"
cat > "$NOTE_CHART/templates/zz-passkey-note.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: passkey-note
data:
  note: {{ include "evtivity-csms.passkeyPortalNote" . | quote }}
YAML
cat > "$TMP/ip-portal.yaml" <<'YAML'
gatewayAPI:
  routes:
    - host: csms.evtivity.local
      rules:
        - path: /
          service: csms
    - host: 192.168.1.20
      rules:
        - path: /
          service: portal
YAML
note() {
  helm template t "$NOTE_CHART" "${S[@]}" --show-only templates/zz-passkey-note.yaml "$@" > "$TMP/note.yaml" 2> "$TMP/note.err"
}
if note --set api.env.webauthnRpId=evtivity.local; then
  if grep -q 'note: ""' "$TMP/note.yaml"; then ok; else bad "passkey note: parent domain of the portal: note shown"; fi
else
  bad "passkey note: parent domain: render failed: $(head -1 "$TMP/note.err")"
fi
if note --set api.env.webauthnRpId=csms.evtivity.local; then
  if grep -q 'is not the portal host portal.evtivity.local or a parent domain of it' "$TMP/note.yaml"; then ok; else
    bad "passkey note: CSMS-only RP ID: portal note missing"
  fi
else
  bad "passkey note: CSMS-only RP ID: render failed: $(head -1 "$TMP/note.err")"
fi
if note --set api.env.webauthnRpId=csms.evtivity.local -f "$TMP/ip-portal.yaml"; then
  if grep -q 'the portal is served from the IP address 192.168.1.20' "$TMP/note.yaml"; then ok; else
    bad "passkey note: IP portal: note missing"
  fi
else
  bad "passkey note: IP portal: render failed: $(head -1 "$TMP/note.err")"
fi
if note; then
  if grep -q 'note: ""' "$TMP/note.yaml"; then ok; else bad "passkey note: no RP ID: note shown"; fi
else
  bad "passkey note: no RP ID: render failed: $(head -1 "$TMP/note.err")"
fi

# SIM provider and station signal settings (appSettings.sim): empty keeps the
# dashboard value and the key is not rendered, a set value renders as a JSON
# boolean, number, string (organization id) or list, anything else fails.
SIM_KEYS='["sim.hologram.enabled","sim.hologram.orgId","sim.hologram.apiKeyEnc","sim.sessions.retentionDays",
"sim.sessions.fetchDays","sim.stationSignal.enabled","sim.signal.alertBelowDbm","sim.ocpp16.signalKeys",
"sim.signal.goodDbm","sim.signal.fairDbm"]'
if render "$TMP/sim-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = JSON.parse(process.argv[2]).filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/sim-default.json" "$SIM_KEYS"; then ok; else bad "sim default: keys rendered"; fi
else
  bad "sim default: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/sim-old.json" --set appSettings.sim=null; then ok; else
  bad "sim without the block: render failed: $(head -1 "$TMP/render.err")"
fi
if render "$TMP/sim-set.json" --set appSettings.sim.hologramEnabled=true --set-string appSettings.sim.hologramOrgId=012345 \
  --set appSettings.sim.sessionsFetchDays=1 \
  --set appSettings.sim.stationSignalEnabled=false --set appSettings.sim.signalAlertBelowDbm=-110 \
  --set 'appSettings.sim.ocpp16SignalKeys={SignalStrength,Vendor.Rssi}' \
  --set appSettings.sim.signalGoodDbm=-40 --set appSettings.sim.signalFairDbm=-140; then
  if r=$(expect_json "$TMP/sim-set.json" '{"sim.hologram.enabled":true,"sim.hologram.orgId":"012345","sim.sessions.fetchDays":1,"sim.stationSignal.enabled":false,"sim.signal.alertBelowDbm":-110,"sim.ocpp16.signalKeys":["SignalStrength","Vendor.Rssi"],"sim.signal.goodDbm":-40,"sim.signal.fairDbm":-140}'); then ok; else bad "sim set: $r"; fi
else
  bad "sim set: render failed: $(head -1 "$TMP/render.err")"
fi
# A values file: an unquoted organization id and quoted whole numbers.
printf 'appSettings:\n  sim:\n    hologramOrgId: 98765\n    sessionsFetchDays: "7"\n    signalGoodDbm: -70\n' > "$TMP/sim-values.yaml"
if render "$TMP/sim-file.json" -f "$TMP/sim-values.yaml"; then
  if r=$(expect_json "$TMP/sim-file.json" '{"sim.hologram.orgId":"98765","sim.sessions.fetchDays":7,"sim.signal.goodDbm":-70}'); then ok; else bad "sim values file: $r"; fi
else
  bad "sim values file: render failed: $(head -1 "$TMP/render.err")"
fi
expect_fail "sim.hologramEnabled string" 'appSettings.sim.hologramEnabled "yes" is not supported' --set-string appSettings.sim.hologramEnabled=yes
expect_fail "sim.stationSignalEnabled quoted" 'appSettings.sim.stationSignalEnabled "true" is not supported' --set-string appSettings.sim.stationSignalEnabled=true
expect_fail "sim.hologramOrgId letters" 'appSettings.sim.hologramOrgId "org-12" is not supported' --set appSettings.sim.hologramOrgId=org-12
expect_fail "sim.hologramOrgId too long" 'appSettings.sim.hologramOrgId "1234567890123456" is not supported' --set-string appSettings.sim.hologramOrgId=1234567890123456
expect_fail "sim.sessionsFetchDays low" 'appSettings.sim.sessionsFetchDays "0" is not supported' --set appSettings.sim.sessionsFetchDays=0
expect_fail "sim.sessionsFetchDays high" 'appSettings.sim.sessionsFetchDays "32" is not supported' --set appSettings.sim.sessionsFetchDays=32
expect_fail "sim.sessionsFetchDays fraction" 'appSettings.sim.sessionsFetchDays "1.5" is not supported' --set appSettings.sim.sessionsFetchDays=1.5
expect_fail "sim.signalAlertBelowDbm low" 'appSettings.sim.signalAlertBelowDbm "-141" is not supported' --set appSettings.sim.signalAlertBelowDbm=-141
expect_fail "sim.signalAlertBelowDbm high" 'appSettings.sim.signalAlertBelowDbm "-39" is not supported' --set appSettings.sim.signalAlertBelowDbm=-39
expect_fail "sim.signalAlertBelowDbm positive" 'appSettings.sim.signalAlertBelowDbm "80" is not supported' --set appSettings.sim.signalAlertBelowDbm=80
expect_fail "sim.signalGoodDbm word" 'appSettings.sim.signalGoodDbm "good" is not supported' --set appSettings.sim.signalGoodDbm=good
expect_fail "sim.signalFairDbm high" 'appSettings.sim.signalFairDbm "-30" is not supported' --set appSettings.sim.signalFairDbm=-30
expect_fail "sim good not above fair" 'appSettings.sim.signalGoodDbm -85 must be above appSettings.sim.signalFairDbm -85' --set appSettings.sim.signalGoodDbm=-85 --set appSettings.sim.signalFairDbm=-85
expect_fail "sim good below fair" 'appSettings.sim.signalGoodDbm -90 must be above appSettings.sim.signalFairDbm -80' --set appSettings.sim.signalGoodDbm=-90 --set appSettings.sim.signalFairDbm=-80
expect_fail "sim.ocpp16SignalKeys not a list" 'appSettings.sim.ocpp16SignalKeys must be a list' --set appSettings.sim.ocpp16SignalKeys=SignalStrength
expect_fail "sim.ocpp16SignalKeys blank entry" 'appSettings.sim.ocpp16SignalKeys entry "" is not a configuration key name' --set 'appSettings.sim.ocpp16SignalKeys[0]='
expect_fail "sim.ocpp16SignalKeys number entry" 'appSettings.sim.ocpp16SignalKeys entry "7" is not a configuration key name' --set 'appSettings.sim.ocpp16SignalKeys={Rssi,7}'
expect_fail "sim.ocpp16SignalKeys long entry" 'is longer than 50 characters' --set "appSettings.sim.ocpp16SignalKeys[0]=$(printf 'K%.0s' $(seq 1 51))"
expect_fail "sim.ocpp16SignalKeys duplicate" 'appSettings.sim.ocpp16SignalKeys lists a key more than once' --set 'appSettings.sim.ocpp16SignalKeys={Rssi,Rssi}'
expect_fail "sim.ocpp16SignalKeys too many" 'appSettings.sim.ocpp16SignalKeys lists 21 keys' --set "appSettings.sim.ocpp16SignalKeys={$(seq -f 'K%g' 1 21 | paste -sd, -)}"

# SIM_PROVIDER_TEST_BASE_URL (the SIM provider mock) is for the local Compose
# stack only: any chart value for it fails the render.
sim_cm_render() {
  helm template t "$CHART" "${S[@]}" --show-only templates/configmap.yaml "$@" > "$TMP/simcm.yaml" 2> "$TMP/simcm.err"
}
if sim_cm_render; then
  if grep -q 'SIM_PROVIDER_TEST_BASE_URL' "$TMP/simcm.yaml"; then bad "SIM mock default: rendered"; else ok; fi
else
  bad "SIM mock default: render failed: $(head -1 "$TMP/simcm.err")"
fi
for spec in 'simProviders.testBaseUrl|simProviders.testBaseUrl is not supported' 'api.env.simProviderTestBaseUrl|api.env.simProviderTestBaseUrl is not supported' 'ocpp.env.simProviderTestBaseUrl|ocpp.env.simProviderTestBaseUrl is not supported' 'worker.env.simProviderTestBaseUrl|worker.env.simProviderTestBaseUrl is not supported' 'ocpi.env.simProviderTestBaseUrl|ocpi.env.simProviderTestBaseUrl is not supported'; do
  key="${spec%%|*}"
  want="${spec#*|}"
  for value in 'http://sim-mock:8080' ''; do
    if sim_cm_render --set "$key=$value"; then
      bad "SIM mock $key=$value: render passed"
    elif grep -qF "$want" "$TMP/simcm.err"; then ok; else
      bad "SIM mock $key=$value: wrong error: $(head -1 "$TMP/simcm.err")"
    fi
  done
done


# Data retention is set in the CSMS under Settings > Data Retention (v0.1.48):
# the chart renders no retention setting and refuses every old value.
RETENTION_KEYS='["audit.retentionDays","refreshTokens.retentionDays","logs.access.retentionDays",
"logs.ocppMessage.retentionDays","logs.domainEvents.retentionDays","logs.meterValues.retentionDays",
"logs.connection.retentionDays","logs.notifications.retentionDays","logs.securityEvents.retentionDays",
"logs.portStatus.retentionDays","logs.workerJob.retentionDays","logs.loadAllocation.retentionDays",
"logs.loginAudit.retentionDays","sim.sessions.retentionDays","ai.conversationRetentionDays",
"aiInsights.retentionDays"]'
if render "$TMP/retention-default.json"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = JSON.parse(process.argv[2]).filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/retention-default.json" "$RETENTION_KEYS"; then ok; else bad "retention default: keys rendered"; fi
else
  bad "retention default: render failed: $(head -1 "$TMP/render.err")"
fi
for v in audit.retentionDays=730 refreshTokens.retentionDays=14 logs.accessRetentionDays=7 \
  logs.ocppMessageRetentionDays=14 logs.domainEventsRetentionDays=7 logs.meterValuesRetentionDays=0 \
  logs.connectionRetentionDays=60 logs.notificationsRetentionDays=60 logs.securityEventsRetentionDays=180 \
  logs.portStatusRetentionDays=7 logs.workerJobRetentionDays=7 logs.loadAllocationRetentionDays=30 \
  logs.loginAuditRetentionDays=30 sim.sessionsRetentionDays=90 ai.conversationRetentionDays=30 \
  aiInsights.retentionDays=90; do
  expect_fail "removed $v" "appSettings.${v%%=*} was removed: data retention is set in the CSMS under Settings > Data Retention" --set "appSettings.$v"
done
# An older release's default values (helm upgrade --reuse-values) render as they are:
# they equal what the older chart wrote, so the guard ignores them.
printf 'appSettings:\n  audit:\n    retentionDays: 1095\n  refreshTokens:\n    retentionDays: 30\n  logs:\n    accessRetentionDays: 30\n    ocppMessageRetentionDays: 30\n    domainEventsRetentionDays: 30\n    meterValuesRetentionDays: 90\n    connectionRetentionDays: 90\n    notificationsRetentionDays: 90\n    securityEventsRetentionDays: 365\n    portStatusRetentionDays: 30\n    workerJobRetentionDays: 30\n    loadAllocationRetentionDays: 90\n    loginAuditRetentionDays: 90\n  sim:\n    sessionsRetentionDays: ""\n  ai:\n    conversationRetentionDays: ""\n  aiInsights:\n    retentionDays: ""\n' > "$TMP/retention-old.yaml"
if render "$TMP/retention-old.json" -f "$TMP/retention-old.yaml"; then
  if node -e '
    const got = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const present = JSON.parse(process.argv[2]).filter((k) => k in got);
    if (present.length) { console.log("rendered " + present.join(", ")); process.exit(1); }
  ' "$TMP/retention-old.json" "$RETENTION_KEYS"; then ok; else bad "retention old defaults: keys rendered"; fi
else
  bad "retention old defaults: render failed: $(head -1 "$TMP/render.err")"
fi
# A changed value carried by --reuse-values renders once the groups are cleared.
if render "$TMP/retention-cleared.json" --set appSettings.logs=null --set appSettings.audit=null \
  --set appSettings.refreshTokens=null; then ok; else
  bad "retention cleared: render failed: $(head -1 "$TMP/render.err")"
fi

# api.env.trustProxy is required behind an HTTPS gateway or one the chart does not create (R2-L3).
for v in 'gatewayAPI.gateway.listeners[0].protocol=HTTPS' 'gatewayAPI.gateway.create=false'; do
  if helm template t "$CHART" "${S[@]}" --set "$v" --set 'gatewayAPI.parentRefs[0].name=gw' > /dev/null 2> "$TMP/tp.err"; then
    bad "trustProxy: $v rendered without api.env.trustProxy"
  elif grep -q 'api.env.trustProxy is required' "$TMP/tp.err"; then ok; else
    bad "trustProxy: $v refused for another reason: $(head -1 "$TMP/tp.err")"
  fi
  if helm template t "$CHART" "${S[@]}" --set "$v" --set 'gatewayAPI.parentRefs[0].name=gw' \
    --set api.env.trustProxy=10.244.0.0/16 > /dev/null 2> "$TMP/tp.err"; then ok; else
    bad "trustProxy: $v with api.env.trustProxy refused: $(head -1 "$TMP/tp.err")"
  fi
done
# The default HTTP gateway still renders without it (the install notes warn).
if helm template t "$CHART" "${S[@]}" > /dev/null 2> "$TMP/tp.err"; then ok; else
  bad "trustProxy: the default HTTP gateway refused: $(head -1 "$TMP/tp.err")"
fi

echo "app settings render tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
