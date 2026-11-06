# pi-unst33r

**UNST33R API provider for the [pi coding agent](https://pi.dev).**

This package registers the [UNST33R API](https://unst33r.si) — an OpenAI-compatible API serving uncensored and abliterated models — as a provider in pi, so its models appear directly in `/model` with correct metadata. No hand-editing JSON.

## Install

```bash
pi install git:github.com/unst33r-si/pi-unst33r
export UNST33R_API_KEY=sk-your-key
```

Open pi, press `/model`, pick an UNST33R model, press `Ctrl+S` to save it as your default.

New to the provider? After installing, ask your agent to use the bundled `unst33r-setup` skill — it walks through key setup, a free catalog check, a tiny paid inference check, and default-model selection. Run it directly with `/skill:unst33r-setup`.

> npm distribution (`pi install npm:@unst33r/pi`) is planned once the package stabilizes.

## Models

Prices are USD per 1M tokens, from the official pricing page (catalog version `2026-10-15-launch-v1`). Context windows reflect the upstream models as listed in pi's own catalog; they have not yet been confirmed end-to-end through the UNST33R gateway.

| Model ID | Base model | Input | Output | Cached input | Context | Reasoning | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `unst33r-flash` | GLM-5.3-Flash (uncensored) | $0.50 | $1.50 | — | 1M | `low` / `high` / `max` | Fast tier; verified working 2026-11-06 |
| `unst33r-deepseek` | DeepSeek-V4.1-Flash-1017 (abliterated) | $0.15 | $0.5625 | $0.03125 | 1M | `off` / `low` / `high` / `max` | Upstream failing (HTTP 400 `upstream_error`) as of 2026-11-06; non-streaming text only per docs — do not rely on it |
| `unst33r-pro` | GLM-5.3 (uncensored) | $2.50 | $4.50 | — | 1M | `low` / `high` / `max` | Flagship tier; verified working 2026-11-06 |

See [unst33r.si](https://unst33r.si) for authoritative pricing.

## Compatibility notes

Live-verified against the gateway on 2026-11-06 with spaced single probes (`scripts/check-compat.sh`). The gateway runs a strict request middleware in front of a New API distributor; rejected requests answer HTTP 503 with alternating errors (`model_not_found` / "No available channel" and a custom `intent_rejected` / "Inference temporarily unavailable").

Accepted (encoded as pi `compat` flags in `extensions/unst33r.ts`):

- **Chat Completions with `max_completion_tokens`** — the legacy `max_tokens` spelling is **rejected** by the middleware; this package sets `maxTokensField: "max_completion_tokens"`.
- **`system` role** works; the `developer` role is rejected (`supportsDeveloperRole: false`).
- **`reasoning_effort`** (`thinkingFormat: "openai"`): flash/pro accept omitted, `low`, `high`, `max` — all verified with `reasoning_content` in non-stream responses. `off` is documented for deepseek only. Other values (`medium`, `off` on GLM tiers) are rejected; pi's `thinkingLevelMap` leaves them unmapped so pi omits the parameter.
- **Output cap: 8192 tokens.** `max_completion_tokens` is accepted up to 8192; 10240 and above are rejected. This package sets `maxTokens: 8192` accordingly.
- **Streaming requires `stream_options.include_usage: true`** — without it the middleware rejects the stream (it does not auto-add the flag as the docs claim). pi sends it when `supportsUsageInStreaming: true`, so this package works. `finish_reason` and a final usage chunk verified; note that **reasoning content is not exposed in stream deltas** (only counted in `usage.completion_tokens_details.reasoning_tokens`).
- **Tool calls: one explicitly selected function** (`tool_choice`) with flat arguments — verified working, matching the documented profile.

Rejected / broken (also verified):

- `temperature` / `top_p` (sampling controls) — pi never sends them by default; do not configure `samplingParams` for these models.
- Both max-field spellings together.
- **Multiple tools with auto selection — i.e. what pi's agent loop sends — are rejected.** Only `tool_choice` forced to one named function is accepted.
- **Array-form message content is rejected** (`[{"type":"text",...}]`): message content must be a plain string. This is stricter than the OpenAI spec, and pi's openai-completions implementation always sends array form for user messages — with no compat flag to change that. **As of 2026-11-06 this blocks pi end-to-end calls through this gateway**, independent of everything above. Raw API calls with string content work (verified end-to-end).
- A content-based "intent" layer additionally classifies prompt text: short/benign prompts pass, but an agent-harness system prompt combined with security-audit/exploit-hunting project instructions was rejected with the same 503 signatures (each part in isolation passed). Expect occasional content-dependent rejections.
- `unst33r-deepseek`'s upstream returned `400 upstream_error` ("Model request failed") during verification, and streaming is rejected for it per docs — treat the tier as non-functional for now.
- Rapid-fire requests can trip the middleware into rejecting even valid bodies. Space requests ~10 seconds apart (the bundled probe script does this via `PROBE_DELAY`).

Run the probe suite yourself:

```bash
export UNST33R_API_KEY=sk-...
bash scripts/check-compat.sh                 # flash tier (default)
bash scripts/check-compat.sh --all-models    # also probes deepseek + pro
```

## Manual configuration (no package)

If you prefer not to install provider code, add this to `~/.pi/agent/models.json` instead:

```json
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "unst33r": {
      "name": "UNST33R",
      "baseUrl": "https://api.unst33r.si/v1",
      "api": "openai-completions",
      "apiKey": "$UNST33R_API_KEY",
      "models": [
        {
          "id": "unst33r-flash",
          "name": "GLM-5.3-Flash uncensored",
          "cost": { "input": 0.5, "output": 1.5, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

## Roadmap

- [x] Verify pricing from the official pricing page; encode reasoning support and `thinkingLevelMap`
- [x] `compat` flags verified against the live gateway (max_completion_tokens, developer role, reasoning_effort set, include_usage-required streaming, single-function tool profile, temperature rejection, 8192 output cap)
- [x] `unst33r-setup` skill: guided key setup and connectivity check
- [ ] **Blocked server-side**: pi end-to-end traffic — the gateway rejects array-form message content (pi has no flatten option) and non-forced multi-tool requests; report both to UNST33R support and re-test after a gateway fix
- [ ] Re-test `unst33r-deepseek` (upstream was failing 2026-11-06)
- [ ] Confirm context windows end-to-end (metadata currently upstream-derived)
- [ ] Dynamic model discovery (`refreshModels`) with the static catalog as fallback
- [ ] npm publish under `@unst33r/pi` with the `pi-package` keyword

## Security notes

- This package ships provider extension code that runs inside pi. As with any third-party pi package, review the source before installing — the tag is pinned when you install via `git:...@v1`.
- Your API key is only read from the `UNST33R_API_KEY` environment variable. It is never written to disk by this package and never hard-coded anywhere.
- UNST33R serves uncensored/abliterated models. Use is subject to their [acceptable-use policy](https://unst33r.si).

## License

[MIT](LICENSE)
