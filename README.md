# pi-unst33r

**UNST33R API provider for the [pi coding agent](https://pi.dev).**

This package registers the [UNST33R API](https://unst33r.si) — an OpenAI-compatible API serving uncensored and abliterated models — as a provider in pi, so its models appear directly in `/model` with correct metadata. No hand-editing JSON.

## Install

```bash
pi install git:github.com/unst33r-si/pi-unst33r
export UNST33R_API_KEY=sk-your-key
```

Open pi, press `/model`, pick an UNST33R model, press `Ctrl+S` to save it as your default.

> npm distribution (`pi install npm:@unst33r/pi`) is planned once the package stabilizes.

## Models

| Model ID | Base model | Notes |
| --- | --- | --- |
| `unst33r-flash` | GLM-5.3-Flash (uncensored) | Fast tier |
| `unst33r-deepseek` | DeepSeek-V4.1-Flash-1017 (abliterated) | |
| `unst33r-pro` | GLM-5.3 (uncensored) | Flagship tier |

Pricing, context windows, and capability flags are being verified against the live API — see [unst33r.si](https://unst33r.si) for authoritative pricing.

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

- [ ] Verify model catalog, context windows, pricing, and reasoning support against the live API
- [ ] `compat` flags for OpenAI-compatibility differences observed through gateways (New API deployments)
- [ ] Dynamic model discovery (`refreshModels`) with the static catalog as fallback
- [ ] `unst33r-setup` skill: guided key setup and connectivity check
- [ ] npm publish under `@unst33r/pi` with the `pi-package` keyword

## Security notes

- This package ships provider extension code that runs inside pi. As with any third-party pi package, review the source before installing — the tag is pinned when you install via `git:...@v1`.
- Your API key is only read from the `UNST33R_API_KEY` environment variable. It is never written to disk by this package and never hard-coded anywhere.

## License

[MIT](LICENSE)
