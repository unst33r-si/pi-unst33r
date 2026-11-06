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
| `unst33r-flash` | GLM-5.3-Flash (uncensored) | $0.50 | $1.50 | — | 1M | `low` / `high` / `max` | Fast tier; tool calls limited to one forced function |
| `unst33r-deepseek` | DeepSeek-V4.1-Flash-1017 (abliterated) | $0.15 | $0.5625 | $0.03125 | 1M | `off` / `low` / `high` / `max` | **Non-streaming text only — no SSE, no tool calls; cannot drive pi's coding loop** |
| `unst33r-pro` | GLM-5.3 (uncensored) | $2.50 | $4.50 | — | 1M | `low` / `high` / `max` | Flagship tier; tool calls limited to one forced function |

See [unst33r.si](https://unst33r.si) for authoritative pricing.

## Compatibility notes

Verified against the official API docs ([unst33r.si/docs](https://unst33r.si/docs)) and encoded as pi `compat` flags in `extensions/unst33r.ts`:

- **Text Chat Completions only.** No Responses API, no structured outputs (`supportsStrictMode: false`), no images/audio/embeddings, no sampling controls — pi never sends `temperature`/`top_p` by default, but don't configure them for these models.
- **`max_tokens` OR `max_completion_tokens`, never both.** This package uses `max_tokens` (`maxTokensField`). If neither is sent the server defaults output to 512 tokens — pi always sends it, so this doesn't affect you here.
- **`reasoning_effort`** (`thinkingFormat: "openai"`): flash/pro accept omitted, `low`, `high`, `max`; deepseek also accepts `off`. Other values are rejected with HTTP 400 rather than clamped — pi's `thinkingLevelMap` therefore leaves `minimal`/`medium`/`xhigh` unmapped.
- **Streaming usage**: the server adds `stream_options.include_usage: true` itself for flash/pro when omitted (`supportsUsageInStreaming: true`).
- **`developer` role**: unverified through the gateway; the package conservatively keeps the `system` role (`supportsDeveloperRole: false`).
- **Tool profile (flash/pro)**: documented as one explicitly selected function with flat string arguments at `reasoning_effort: low`. pi's agent loop sends multiple tools with auto selection — treat full agentic use as unverified until probed; the deepseek tier has no tool calling at all.
- **`unst33r-deepseek` is non-streaming text only** (no SSE, no tool calls), so it is registered for catalog completeness and one-shot text use, not as an agent model.

`scripts/check-compat.sh` probes all of the above against the live endpoint and prints a suggested `compat` block:

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
- [x] `compat` flags for OpenAI-compatibility differences observed at the gateway (New API deployment), from official docs
- [x] `unst33r-setup` skill: guided key setup and connectivity check
- [ ] Confirm context windows, output limits, and tool-calling behavior with live completion probes (`scripts/check-compat.sh`) — pending gateway channel availability
- [ ] Dynamic model discovery (`refreshModels`) with the static catalog as fallback
- [ ] npm publish under `@unst33r/pi` with the `pi-package` keyword

## Security notes

- This package ships provider extension code that runs inside pi. As with any third-party pi package, review the source before installing — the tag is pinned when you install via `git:...@v1`.
- Your API key is only read from the `UNST33R_API_KEY` environment variable. It is never written to disk by this package and never hard-coded anywhere.
- UNST33R serves uncensored/abliterated models. Use is subject to their [acceptable-use policy](https://unst33r.si).

## License

[MIT](LICENSE)
