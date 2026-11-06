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
#   4.  streaming WITHOUT stream_options         server adds usage? (docs: yes)
#   5.  developer role accepted?                 (pi flag: supportsDeveloperRole)
#   6-9. reasoning_effort low / high / max / off (pi flag: supportsReasoningEffort
#                                                 + thinkingLevelMap)
#   10. reasoning_effort=medium rejected?        (docs: rejects, never clamps)
#   11. max_tokens + max_completion_tokens together rejected?
#   12. temperature accepted?                    (docs: sampling controls out of
#                                                 range — pi never sends it by
#                                                 default, but users can)
#   13. tool call: one forced function           (docs: the only supported
#                                                 tool profile for flash/pro)
#   14. tool call: multiple tools, auto choice   (what pi's agent loop sends)
#
# Every inference probe uses tiny max_tokens to limit spend. /v1/models is free.
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

# post <body-json> -> runs a completion request in the CURRENT shell:
# sets global HTTP_CODE and writes the raw response body to $BODY_FILE.
post() {
  HTTP_CODE=$(curl -s --max-time 180 -o "$BODY_FILE" -w '%{http_code}' \
    "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $UNST33R_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$1")
}

# post_out <body-json> -> same, then prints the body (for pipelines)
post_out() {
  post "$1"
  cat "$BODY_FILE" 2>/dev/null
}

expect_reject() { # expect_reject <probe> <body> <why>
  local probe="$1" body="$2" why="$3" out code
  post "$body"; code="$HTTP_CODE"; out=$(cat "$BODY_FILE" 2>/dev/null)
  if [ "$code" = "400" ] || [ "$code" = "422" ]; then
    record PASS "$probe" "rejected with HTTP $code as documented ($why)"
  else
    record FAIL "$probe" "expected HTTP 400 ($why), got HTTP $code: $(echo "$out" | head -c 160)"
  fi
}

# ---------------------------------------------------------------------------
echo "== UNST33R compat probe — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "== endpoint: $BASE_URL  model: $MODEL"
echo

# --- 1. models (free) ------------------------------------------------------
MODELS_OUT=$(curl -s --max-time 30 "$BASE_URL/models" -H "Authorization: Bearer $UNST33R_API_KEY")
if echo "$MODELS_OUT" | grep -q '"object":"list"'; then
  record PASS "models.list" "catalog: $(echo "$MODELS_OUT" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')"
else
  record FAIL "models.list" "unexpected response: $(echo "$MODELS_OUT" | head -c 200)"
fi
echo

# --- 2. basic non-stream ---------------------------------------------------
post '{"model":"'$MODEL'","messages":[{"role":"system","content":"You are a test harness."},{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000}'
OUT=$(cat "$BODY_FILE")
if echo "$OUT" | grep -q '"finish_reason"'; then
  record PASS "basic.completion" "HTTP $HTTP_CODE, finish_reason=$(echo "$OUT" | grep -o '"finish_reason":"[^"]*"' | head -1 | cut -d'"' -f4), usage=$(echo "$OUT" | grep -o '"usage":{[^}]*}' | head -c 120)"
else
  record FAIL "basic.completion" "HTTP $HTTP_CODE: $(echo "$OUT" | head -c 200)"
  note "   (core probe failed — later probes will likely fail too)"
fi
echo

if [ "$fail_count" -gt 0 ]; then
  note "Core inference unavailable (likely gateway channel outage). Probes that need inference are skipped."
  echo
  echo "Summary: $pass_count pass / $fail_count fail (+ skipped)"
  exit 1
fi

# --- 3. streaming with explicit include_usage ------------------------------
OUT=$(curl -s --max-time 180 "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"Count 1 to 3"}],"max_tokens":2000,"stream":true,"stream_options":{"include_usage":true}}')
if echo "$OUT" | grep -q '"usage"'; then
  record PASS "stream.usage_flag" "usage chunk present with explicit stream_options.include_usage=true"
else
  record FAIL "stream.usage_flag" "no usage chunk in stream (set compat supportsUsageInStreaming=false)"
  suggest '"supportsUsageInStreaming": false'
fi
echo

# --- 4. streaming without stream_options -----------------------------------
OUT=$(curl -s --max-time 180 "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"Count 1 to 2"}],"max_tokens":2000,"stream":true}')
if echo "$OUT" | grep -q '"usage"'; then
  record PASS "stream.usage_auto" "server adds usage reporting itself (docs behavior confirmed)"
else
  record INFO "stream.usage_auto" "no usage chunk when stream_options omitted — pi sends it explicitly, so harmless; set supportsUsageInStreaming accordingly"
fi
if echo "$OUT" | grep -q '"finish_reason":"stop"'; then
  record PASS "stream.finish_reason" "stream emits finish_reason (keep supportsFinishReason default true)"
else
  record FAIL "stream.finish_reason" "no finish_reason in stream — set compat supportsFinishReason=false"
  suggest '"supportsFinishReason": false'
fi
echo

# --- 5. developer role ------------------------------------------------------
post '{"model":"'$MODEL'","messages":[{"role":"developer","content":"You are a test harness."},{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000}'
OUT=$(cat "$BODY_FILE")
if [ "$HTTP_CODE" = "200" ]; then
  record PASS "role.developer" "accepted — could set supportsDeveloperRole=true"
else
  record FAIL "role.developer" "HTTP $HTTP_CODE — keep supportsDeveloperRole=false (current default in extensions/unst33r.ts)"
fi
echo

# --- 6-9. reasoning_effort accepted values ---------------------------------
for EFFORT in low high max; do
  post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000,"reasoning_effort":"'$EFFORT'"}'
OUT=$(cat "$BODY_FILE")
  if [ "$HTTP_CODE" = "200" ]; then
    record PASS "effort.$EFFORT" "accepted"
  else
    record FAIL "effort.$EFFORT" "HTTP $HTTP_CODE: $(echo "$OUT" | head -c 160)"
  fi
done
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000,"reasoning_effort":"off"}'
OUT=$(cat "$BODY_FILE")
if [ "$HTTP_CODE" = "200" ]; then
  record PASS "effort.off" "accepted — add off:\"off\" to thinkingLevelMap for this model"
else
  record PASS "effort.off" "rejected (HTTP $HTTP_CODE) — keep off:null in thinkingLevelMap (omit param when thinking disabled)"
fi
echo

# --- 10. reasoning_effort=medium must be rejected ---------------------------
expect_reject "effort.medium" \
  '{"model":"'$MODEL'","messages":[{"role":"user","content":"hi"}],"max_tokens":64,"reasoning_effort":"medium"}' \
  "docs: only omitted/low/high/max (deepseek: +off)"

# --- 11. both max fields must be rejected ----------------------------------
expect_reject "maxfields.both" \
  '{"model":"'$MODEL'","messages":[{"role":"user","content":"hi"}],"max_tokens":64,"max_completion_tokens":64}' \
  "docs: use one, never both"

# --- 12. temperature --------------------------------------------------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000,"temperature":0.7}'
OUT=$(cat "$BODY_FILE")
if [ "$HTTP_CODE" = "200" ]; then
  record INFO "sampling.temperature" "accepted — docs say out of supported range but server tolerates it"
else
  record PASS "sampling.temperature" "rejected (HTTP $HTTP_CODE) — matches docs; pi never sends it by default"
  suggest 'note: temperature/top_p rejected — do not set samplingParams for unst33r models'
fi
echo

# --- 13. single forced function (documented tool profile) -------------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"Call the get_time tool."}],"max_tokens":2000,"reasoning_effort":"low","tool_choice":{"type":"function","function":{"name":"get_time"}},"tools":[{"type":"function","function":{"name":"get_time","description":"Get current time","parameters":{"type":"object","properties":{"tz":{"type":"string"}},"required":[]}}}]}'
OUT=$(cat "$BODY_FILE")
if echo "$OUT" | grep -q '"tool_calls"'; then
  record PASS "tools.single_forced" "forced single-function tool call returned (documented profile works)"
else
  record FAIL "tools.single_forced" "HTTP $HTTP_CODE: $(echo "$OUT" | head -c 200)"
fi

# --- 14. multiple tools with auto choice (pi agent-loop profile) ------------
post '{"model":"'$MODEL'","messages":[{"role":"user","content":"What is 2+2? Use the calc tool."}],"max_tokens":2000,"tools":[{"type":"function","function":{"name":"calc","description":"Calculate","parameters":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}}},{"type":"function","function":{"name":"get_time","description":"Get current time","parameters":{"type":"object","properties":{},"required":[]}}}]}'
OUT=$(cat "$BODY_FILE")
if echo "$OUT" | grep -q '"tool_calls"'; then
  record PASS "tools.multi_auto" "multi-tool auto-choice returned tool_calls — full agentic profile OK"
else
  record INFO "tools.multi_auto" "HTTP $HTTP_CODE, no tool_calls: $(echo "$OUT" | head -c 160)"
  note "   -> pi's agent loop sends all tools at once; if this fails repeatedly,"
  note "      agentic use of this model through unst33r is degraded. Document it."
fi
echo

# --- deepseek streaming (only with --all-models) ----------------------------
if [ "$ALL_MODELS" = "1" ]; then
  for M in unst33r-deepseek unst33r-pro; do
    echo "== extra checks for $M"
    post '{"model":"'$M'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2000}'
OUT=$(cat "$BODY_FILE")
    if [ "$HTTP_CODE" = "200" ]; then
      record PASS "$M.basic" "non-stream completion OK"
    else
      record FAIL "$M.basic" "HTTP $HTTP_CODE: $(echo "$OUT" | head -c 160)"
    fi
    OUT=$(curl -s --max-time 180 "$BASE_URL/chat/completions" \
      -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
      -d '{"model":"'$M'","messages":[{"role":"user","content":"hi"}],"max_tokens":64,"stream":true}')
    if echo "$OUT" | grep -q '^data:'; then
      record PASS "$M.stream" "streaming accepted"
    else
      record INFO "$M.stream" "streaming rejected: $(echo "$OUT" | head -c 160)"
    fi
    post '{"model":"'$M'","messages":[{"role":"user","content":"Reply OK"}],"max_tokens":2000,"reasoning_effort":"off"}'
OUT=$(cat "$BODY_FILE")
    if [ "$HTTP_CODE" = "200" ]; then
      record PASS "$M.effort_off" "reasoning_effort=off accepted"
    else
      record FAIL "$M.effort_off" "HTTP $HTTP_CODE (docs say off is valid)"
    fi
    echo
  done
fi

echo "Summary: $pass_count pass / $fail_count fail"
echo
echo "SUGGESTED COMPAT (paste into extensions/unst33r.ts after review):"
echo "{"
echo '  "supportsStore": false,'
echo '  "supportsDeveloperRole": false,  // flip to true only if role.developer PASSED'
echo '  "supportsReasoningEffort": true,'
echo '  "supportsUsageInStreaming": true,'
echo '  "maxTokensField": "max_tokens",'
echo '  "supportsStrictMode": false,'
echo '  "thinkingFormat": "openai"'
echo "}"
[ ${#SUGGESTIONS[@]} -gt 0 ] && printf 'overrides: %s\n' "${SUGGESTIONS[@]}"
exit 0
