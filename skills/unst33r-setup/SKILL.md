---
name: unst33r-setup
description: Set up and verify the UNST33R API provider for pi — configure UNST33R_API_KEY, verify connectivity and model access, pick a default model. Use when the user mentions UNST33R, unst33r.si, pi-unst33r, asks to configure/verify the unst33r provider, or hits unst33r API errors (401, 403, "No available channel", 429).
---

# UNST33R setup for pi

Guide the user through connecting the UNST33R API (https://api.unst33r.si/v1) to pi. Run every network step yourself with bash and report results; never print or store the API key value in output, logs, or files.

## Step 1 — Check for an API key

```bash
if [ -z "$UNST33R_API_KEY" ]; then echo "NOT SET"; else echo "SET (${#UNST33R_API_KEY} chars)"; fi
```

If not set, ask the user to create one in the UNST33R console (https://unst33r.si → "Get API key") and export it:

```bash
export UNST33R_API_KEY=sk-...
```

Suggest persisting it in their shell profile or a `chmod 600` env file they source manually. Never write the key into any project file, command history you control, or this skill's output.

## Step 2 — Verify the key and catalog (free, no balance consumed)

```bash
curl -s --max-time 30 https://api.unst33r.si/v1/models \
  -H "Authorization: Bearer $UNST33R_API_KEY"
```

Expected: `"object":"list"` with three models — `unst33r-flash`, `unst33r-deepseek`, `unst33r-pro`.

Interpreting failures:

- HTTP 401 `invalid credentials` → key missing/malformed; go back to Step 1.
- HTTP 403 → key valid but access denied for this route; user should check the console.
- Connection/timeout errors → network or service issue; suggest retrying later.

Note: `/v1/models` reflects the routes the key *may* use. It does NOT prove inference works — that needs Step 3.

## Step 3 — Verify inference (consumes a tiny amount of balance)

Send one minimal request to the cheapest capable tier (`unst33r-flash`):

```bash
curl -s --max-time 120 https://api.unst33r.si/v1/chat/completions \
  -H "Authorization: Bearer $UNST33R_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"unst33r-flash","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":2000}'
```

Expected: `choices[0].message.content` containing "OK" (plus `reasoning_content` on reasoning tiers) and a `usage` object.

Gateway quirks to keep in mind (verified 2026-11-06, see the package README's Compat section for the full list):

- Use `max_completion_tokens`, never `max_tokens` (the legacy spelling is rejected).
- Keep message content as plain strings; array-of-blocks content is rejected.
- Space requests ~10s apart — rapid-fire requests can trip the middleware (`503 intent_rejected`) even for valid bodies.

- `model_not_found` / `"No available channel ... under group default"` / `intent_rejected` / `"Inference temporarily unavailable"` → these 503 signatures come from the gateway middleware and alternate between two shapes. They mean either (a) the request contains a parameter or content shape the middleware rejects (see quirks above and the README Compat section), or (b) a temporary server-side condition. Try a minimal body first (`model` + plain-string `messages` only); if that passes, the rejected request's shape is at fault, not the channel.
- HTTP 400 `upstream_error` on `unst33r-deepseek` → the tier's upstream is failing; report and move on.
- HTTP 400 with a field name → request-shape issue; report the exact error body.
- HTTP 429/5xx (other) → temporary upstream errors per the official docs; retry once after ~30s.

If Step 3 succeeds, also run the fuller compatibility probe (optional but recommended):

```bash
bash "<package-dir>/scripts/check-compat.sh"   # <package-dir> is the pi-unst33r package root (skills/..'s parent)
```

## Step 4 — Set the default model in pi

With the extension installed (`pi install git:github.com/unst33r-si/pi-unst33r`) and the key exported, launch pi and:

1. Run `/model` and select **UNST33R / unst33r-pro** (flagship) or **unst33r-flash** (fast, ~5x cheaper).
2. Press `Ctrl+S` to save it as the default.

Model guidance:

- **unst33r-flash** — everyday coding traffic; $0.50/$1.50 per 1M in/out.
- **unst33r-pro** — hardest problems; $2.50/$4.50 per 1M in/out.
- **unst33r-deepseek** — currently non-streaming text only (no SSE, no tool calls per official docs), so it **cannot drive pi's coding loop**. Recommend leaving it as a one-shot/text model until upstream enables streaming.

## Step 5 — Report to the user

Summarize: key status (set/not, never the value), catalog check result, inference check result, chosen default model, and any caveats observed (e.g. channel outage, deepseek limitation). If anything failed in a way the user must fix (no key, no balance, channel outage), say exactly what they need to do next.
