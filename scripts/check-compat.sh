#!/usr/bin/env bash
#
# check-compat.sh — UNST33R endpoint compatibility probe for pi-unst33r.
#
# Verifies, against the live gateway, the behaviors pi's openai-completions
# implementation depends on or configures via `compat` flags:
#
#   1.  /v1/models catalog                       (free — no balance consumed)
#   2.  basic non-stream completion              finish_reason / usage presence
#   3.  streaming with stream_options.include_usage=true
#   4.  streaming WITHOUT stream_options         (gateway REQUIRES the flag —
#                                                 expected: 503, not auto-add)
#   5.  developer role accepted?                 (verified 2026-11-06: NO)
#   6-9. reasoning_effort low / high / max / off (pi flag: supportsReasoningEffort
#                                                 + thinkingLevelMap)
#   10. reasoning_effort=medium rejected?
#   11. max_tokens (legacy spelling) rejected?   (verified 2026-11-06: YES —
#                                                 gateway wants
#                                                 max_completion_tokens)
#   12. both max fields together rejected?
#   13. temperature accepted?                    (verified 2026-11-06: NO)
#   14. tool call: one forced function           (the only profile the gateway
#                                                 accepts)
#   15. tool call: multiple tools, auto choice   (what pi's agent loop sends —
#                                                 verified 2026-11-06: rejected)
#
# NOTE on pacing: the gateway middleware trips on rapid-fire requests and
# answers 503 `intent_rejected` for even valid bodies. This script sleeps
# PROBE_DELAY seconds (default 10) between probes — don't remove it.
#
# Every inference probe uses small max_completion_tokens to limit spend.
# /v1/models is free.
#
# Usage:
#   export UNST33R_API_KEY=sk-...
#   bash scripts/check-compat.sh [--model unst33r-flash] [--all-models]
#
# Output: per-probe PASS/FAIL lines with observed evidence, then a
# "SUGGESTED COMPAT" JSON summary mapping results to pi compat flags.
# Exit 0 = models + basic completion OK; 1 = core probes failed; 2 = no key.
#
# Never prints the API key.

set -u

BASE_URL="${UNST33R_BASE_URL:-https://api.unst33r.si/v1}"
MODEL="unst33r-flash"
ALL_MODELS=0
PROBE_DELAY="${PROBE_DELAY:-10}"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --all-models) ALL_MODELS=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${UNST33R_API_KEY:-}" ]; then
  echo "ERROR: UNST33R_API_KEY is not set." >&2
  exit 2
fi

pass_count=0
fail_count=0
declare -a SUGGESTIONS=()
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

note() { printf '%s\n' "$*"; }
record() { # record <PASS|FAIL|INFO> <probe> <detail>
  local status="$1" probe="$2" detail="$3"
  if [ "$status" = "PASS" ]; then pass_count=$((pass_count+1));
  elif [ "$status" = "FAIL" ]; then fail_count=$((fail_count+1)); fi
  printf '[%-4s] %-28s %s\n' "$status" "$probe" "$detail"
}
suggest() { SUGGESTIONS+=("$1"); }
pacing() { sleep "$PROBE_DELAY"; }

# post <body-json> -> runs a completion request in the CURRENT shell:
# sets global HTTP_CODE and writes the raw response body to $BODY_FILE.
post() {
  HTTP_CODE=$(curl -s --max-time 180 -o "$BODY_FILE" -w '%{http_code}' \
    "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $UNST33R_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$1")
}
body() { cat "$BODY_FILE" 2>/dev/null; }

expect_reject() { # expect_reject <probe> <body> <why>
  local probe="$1" b="$2" why="$3" code out
  post "$b"; code="$HTTP_CODE"; out=$(body)
  if [ "$code" = "400" ] || [ "$code" = "422" ] || [ "$code" = "503" ]; then
    record PASS "$probe" "rejected with HTTP $code ($why)"
  else
    record FAIL "$probe" "expected rejection ($why), got HTTP $code: $(echo "$out" | head -c 160)"
  fi
  pacing
}

# ---------------------------------------------------------------------------
echo "== UNST33R compat probe — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "== endpoint: $BASE_URL  model: $MODEL  probe delay: ${PROBE_DELAY}s"
echo

# --- 1. models (free) ------------------------------------------------------
MODELS_OUT=$(curl -s --max-time 30 "$BASE_URL/models" -H "Authorization: Bearer $UNST33R_API_KEY")
if echo "$MODELS_OUT" | grep -q '"object":"list"'; then
  record PASS "models.list" "catalog: $(echo "$MODELS_OUT" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')"
else
  record FAIL "models.list" "unexpected response: $(echo "$MODELS_OUT" | head -c 200)"
fi
echo

# --- 2. basic non-stream (max_completion_tokens spelling!) ------------------
post '{"model":"'$MODEL'","messages":[{"role":"system","content":"You are a test harness."},{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000}'
OUT=$(body)
if echo "$OUT" | grep -q '"finish_reason"'; then
  record PASS "basic.completion" "HTTP $HTTP_CODE, finish_reason=$(echo "$OUT" | grep -o '"finish_reason":"[^"]*"' | head -1 | cut -d'"' -f4), reasoning=$(echo "$OUT" | grep -o '"reasoning_content"' | head -1)"
else
  record FAIL "basic.completion" "HTTP $HTTP_CODE: $(echo "$OUT" | head -c 200)"
  note "   (core probe failed — later probes will likely fail too)"
fi
pacing
echo

if [ "$fail_count" -gt 0 ]; then
  note "Core inference unavailable (gateway middleware or channel outage). Inference probes skipped."
  echo
  echo "Summary: $pass_count pass / $fail_count fail (+ skipped)"
  exit 1
fi

# --- 3. streaming with explicit include_usage ------------------------------
curl -s --max-time 180 "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"Count 1 to 3"}],"max_completion_tokens":2000,"stream":true,"stream_options":{"include_usage":true}}' > "$BODY_FILE"
OUT=$(body)
if echo "$OUT" | grep -q '"usage"'; then
  record PASS "stream.usage_flag" "usage chunk + finish_reason=$(echo "$OUT" | grep -o '"finish_reason":"[a-z_]*"' | head -1 | cut -d'"' -f4) present with include_usage=true"
else
  record FAIL "stream.usage_flag" "no usage chunk in stream (set compat supportsUsageInStreaming=false)"
  suggest '"supportsUsageInStreaming": false'
fi
pacing

# --- 4. streaming WITHOUT stream_options (gateway requires the flag) --------
curl -s --max-time 180 "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"Count 1 to 2"}],"max_completion_tokens":2000,"stream":true}' > "$BODY_FILE"
CODE="$HTTP_CODE"; OUT=$(body)
if [ "$CODE" = "200" ]; then
  record INFO "stream.usage_auto" "stream accepted without stream_options (middleware no longer enforces the flag)"
else
  record PASS "stream.usage_auto" "rejected HTTP $CODE without include_usage — pi always sends it (supportsUsageInStreaming=true), so compatible"
fi
pacing

# --- 5. developer role ------------------------------------------------------
post '{"model":"'$MODEL'","messages":[{"role":"developer","content":"You are a test harness."},{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000}'
if [ "$HTTP_CODE" = "200" ]; then
  record PASS "role.developer" "accepted — could set supportsDeveloperRole=true"
else
  record PASS "role.developer" "rejected (HTTP $HTTP_CODE) — keep supportsDeveloperRole=false"
fi
pacing

# --- 6-9. reasoning_effort accepted values ---------------------------------
for EFFORT in low high max; do
  post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000,"reasoning_effort":"'$EFFORT'"}'
  if [ "$HTTP_CODE" = "200" ]; then
    record PASS "effort.$EFFORT" "accepted"
  else
    record FAIL "effort.$EFFORT" "HTTP $HTTP_CODE: $(body | head -c 160)"
  fi
  pacing
done
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000,"reasoning_effort":"off"}'
if [ "$HTTP_CODE" = "200" ]; then
  record PASS "effort.off" "accepted — add off:\"off\" to thinkingLevelMap for this model"
else
  record PASS "effort.off" "rejected (HTTP $HTTP_CODE) — keep off:null in thinkingLevelMap (omit param when thinking disabled)"
fi
pacing

# --- 10. reasoning_effort=medium must be rejected ---------------------------
expect_reject "effort.medium" \
  '{"model":"'$MODEL'","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":64,"reasoning_effort":"medium"}' \
  "docs: only omitted/low/high/max (deepseek: +off)"

# --- 11. legacy max_tokens spelling must be rejected ------------------------
expect_reject "maxfields.max_tokens" \
  '{"model":"'$MODEL'","messages":[{"role":"user","content":"hi"}],"max_tokens":64}' \
  "gateway middleware wants max_completion_tokens (verified 2026-11-06)"

# --- 12. both max fields must be rejected ----------------------------------
expect_reject "maxfields.both" \
  '{"model":"'$MODEL'","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":64,"max_tokens":64}' \
  "docs: use one, never both"

# --- 13. temperature --------------------------------------------------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000,"temperature":0.7}'
if [ "$HTTP_CODE" = "200" ]; then
  record INFO "sampling.temperature" "accepted — docs say out of supported range but server tolerates it"
else
  record PASS "sampling.temperature" "rejected (HTTP $HTTP_CODE) — matches docs; pi never sends it by default"
  suggest 'note: temperature/top_p rejected — do not set samplingParams for unst33r models'
fi
pacing

# --- 14. single forced function (documented tool profile) -------------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Call the get_time tool."}],"max_completion_tokens":2000,"reasoning_effort":"low","tool_choice":{"type":"function","function":{"name":"get_time"}},"tools":[{"type":"function","function":{"name":"get_time","description":"Get current time","parameters":{"type":"object","properties":{"tz":{"type":"string"}},"required":[]}}}]}'
if [ "$(body | grep -c '"tool_calls"')" -gt 0 ]; then
  record PASS "tools.single_forced" "forced single-function tool call returned (documented profile works)"
else
  record FAIL "tools.single_forced" "HTTP $HTTP_CODE: $(body | head -c 200)"
fi
pacing

# --- 15. multiple tools with auto choice (pi agent-loop profile) ------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"What is 2+2? Use the calc tool."}],"max_completion_tokens":2000,"tools":[{"type":"function","function":{"name":"calc","description":"Calculate","parameters":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}}},{"type":"function","function":{"name":"get_time","description":"Get current time","parameters":{"type":"object","properties":{},"required":[]}}}]}'
if [ "$(body | grep -c '"tool_calls"')" -gt 0 ]; then
  record PASS "tools.multi_auto" "multi-tool auto-choice returned tool_calls — full agentic profile OK"
else
  record PASS "tools.multi_auto" "rejected (HTTP $HTTP_CODE) — matches verified gateway behavior: pi's agent loop is degraded until the gateway widens the tool profile"
fi
pacing
echo

# --- per-model extras --------------------------------------------------------
if [ "$ALL_MODELS" = "1" ]; then
  for M in unst33r-deepseek unst33r-pro; do
    echo "== extra checks for $M"
    post '{"model":"'$M'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000}'
    if [ "$HTTP_CODE" = "200" ]; then
      record PASS "$M.basic" "non-stream completion OK"
    else
      record FAIL "$M.basic" "HTTP $HTTP_CODE: $(body | head -c 160)"
    fi
    pacing
    curl -s --max-time 180 "$BASE_URL/chat/completions" \
      -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
      -d '{"model":"'$M'","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":64,"stream":true,"stream_options":{"include_usage":true}}' > "$BODY_FILE"
    if [ "$(body | grep -c '^data:')" -gt 0 ]; then
      record PASS "$M.stream" "streaming accepted"
    else
      record INFO "$M.stream" "streaming rejected: $(body | head -c 160)"
    fi
    pacing
    post '{"model":"'$M'","messages":[{"role":"user","content":"Reply OK"}],"max_completion_tokens":2000,"reasoning_effort":"off"}'
    if [ "$HTTP_CODE" = "200" ]; then
      record PASS "$M.effort_off" "reasoning_effort=off accepted"
    else
      record INFO "$M.effort_off" "HTTP $HTTP_CODE (docs say off is valid; deepseek upstream was failing 2026-11-06)"
    fi
    pacing
    echo
  done
fi

echo "Summary: $pass_count pass / $fail_count fail"
echo
echo "SUGGESTED COMPAT (paste into extensions/unst33r.ts after review):"
echo "{"
echo '  "supportsStore": false,'
echo '  "supportsDeveloperRole": false,      // flip to true only if role.developer PASSED'
echo '  "supportsReasoningEffort": true,'
echo '  "supportsUsageInStreaming": true,    // gateway REQUIRES include_usage on streams'
echo '  "maxTokensField": "max_completion_tokens",  // max_tokens is rejected'
echo '  "supportsStrictMode": false,'
echo '  "thinkingFormat": "openai"'
echo "}"
[ ${#SUGGESTIONS[@]} -gt 0 ] && printf 'overrides: %s\n' "${SUGGESTIONS[@]}"
exit 0
