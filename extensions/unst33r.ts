/**
 * pi-unst33r — UNST33R API provider for the pi coding agent.
 *
 * Registers https://api.unst33r.si/v1 (OpenAI Chat Completions behind a New API
 * gateway) as provider "unst33r" with a static model catalog.
 *
 * Metadata sources & verification status (2026-11-06):
 * - Pricing: official pricing page, catalog version 2026-10-15-launch-v1
 *   (https://unst33r.si/pricing).
 * - Context windows / max output: derived from pi's own catalog entries for the
 *   same upstream models (GLM-5.3 / GLM-5.3-Flash / DeepSeek-V4-Flash) and NOT
 *   yet confirmed end-to-end through the gateway — see compat notes below and
 *   scripts/check-compat.sh.
 * - Compatibility flags: from the official API docs (https://unst33r.si/docs).
 *   Live completion-level probes were blocked on 2026-11-06 by a gateway-side
 *   channel outage ("No available channel ... under group default"), so flags
 *   marked (docs) rest on official documentation, and flags marked
 *   (conservative) are deliberately pessimistic until re-verified with
 *   scripts/check-compat.sh.
 *
 * API-level facts from the official docs:
 * - Text Chat Completions only. No Responses API, no structured outputs
 *   (json_schema), no images/audio/embeddings, no sampling controls
 *   (temperature/top_p are outside the supported range).
 * - Set max_tokens OR max_completion_tokens, never both. If neither is set the
 *   server defaults the output limit to 512 tokens.
 * - reasoning_effort: unst33r-flash / unst33r-pro accept omitted | low | high |
 *   max; unst33r-deepseek additionally accepts off. Other values are rejected
 *   (HTTP 400), not silently clamped.
 * - unst33r-deepseek currently accepts non-streaming text only: SSE and tool
 *   calls are NOT enabled for it, so it cannot drive pi's agentic coding loop.
 * - unst33r-flash / unst33r-pro: streaming requires usage reporting; the server
 *   adds stream_options.include_usage=true itself when omitted. Their tool
 *   profile is limited to ONE explicitly selected function with flat string
 *   arguments at reasoning_effort=low — full multi-tool agentic use may be
 *   degraded; verify with scripts/check-compat.sh before relying on it.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Compat flags shared by all three models.
 *
 * - supportsStore: false            (docs) — no store / Responses API.
 * - supportsDeveloperRole: false    (conservative) — unverified through the
 *   gateway; the system role is universally accepted by OpenAI-compatible
 *   relays, so we stay on system until probed otherwise.
 * - supportsReasoningEffort: true   (docs) — reasoning_effort documented.
 * - supportsUsageInStreaming: true  (docs) — server adds
 *   stream_options.include_usage=true when omitted (flash/pro). Harmless for
 *   deepseek, which rejects streaming outright (see its warning).
 * - supportsFinishReason: left at default (true) — unverified; flip after a
 *   check-compat.sh run if streams end without finish_reason.
 * - maxTokensField: "max_tokens"    (docs allows either; "max_tokens" is the
 *   most portable across New API upstream channels).
 * - supportsStrictMode: false       (docs) — structured outputs unsupported.
 * - thinkingFormat: "openai"        (docs) — reasoning_effort is the documented
 *   thinking control.
 */
const SHARED_COMPAT = {
	supportsStore: false,
	supportsDeveloperRole: false,
	supportsReasoningEffort: true,
	supportsUsageInStreaming: true,
	maxTokensField: "max_tokens",
	supportsStrictMode: false,
	thinkingFormat: "openai",
} as const;

/**
 * GLM-based tiers (unst33r-flash, unst33r-pro): reasoning_effort accepts
 * omitted | low | high | max. `off` is NOT in the accepted set, so thinking
 * "off" means omitting the parameter entirely (null). medium/minimal/xhigh are
 * likewise unsupported — the docs promise other values are rejected with 400,
 * never clamped.
 */
const GLM_THINKING_LEVEL_MAP = {
	off: null,
	minimal: null,
	low: "low",
	medium: null,
	high: "high",
	xhigh: null,
	max: "max",
} as const;

/**
 * DeepSeek tier additionally accepts reasoning_effort="off".
 */
const DEEPSEEK_THINKING_LEVEL_MAP = {
	off: "off",
	minimal: null,
	low: "low",
	medium: null,
	high: "high",
	xhigh: null,
	max: "max",
} as const;

/**
 * Output cap: pi always sends max_tokens, and the docs warn the server default
 * is 512 tokens with "larger limits require model-specific verification". 32k
 * is comfortably above pi's per-turn needs (text + tool-call arguments) while
 * staying below any plausible upstream cap. Revisit after a live probe.
 */
const MAX_OUTPUT_TOKENS = 32768;

export default function (pi: ExtensionAPI) {
	pi.registerProvider("unst33r", {
		name: "UNST33R",
		baseUrl: "https://api.unst33r.si/v1",
		apiKey: "$UNST33R_API_KEY",
		api: "openai-completions",
		models: [
			{
				type: "chat",
				id: "unst33r-flash",
				name: "GLM-5.3-Flash Uncensored",
				reasoning: true,
				thinkingLevelMap: GLM_THINKING_LEVEL_MAP,
				input: ["text"],
				cost: { input: 0.5, output: 1.5, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 1_000_000,
				maxTokens: MAX_OUTPUT_TOKENS,
				compat: SHARED_COMPAT,
			},
			{
				type: "chat",
				// WARNING: upstream accepts non-streaming TEXT ONLY — SSE and tool
				// calls are not enabled (official docs). pi's coding loop streams
				// and uses tools, so this model is effectively unusable as an agent
				// model; it is registered because it is part of the documented
				// catalog, for one-shot/text use and future re-verification.
				id: "unst33r-deepseek",
				name: "DeepSeek-V4.1-Flash-1017 Abliterated",
				reasoning: true,
				thinkingLevelMap: DEEPSEEK_THINKING_LEVEL_MAP,
				input: ["text"],
				cost: { input: 0.15, output: 0.5625, cacheRead: 0.03125, cacheWrite: 0 },
				contextWindow: 1_000_000,
				maxTokens: MAX_OUTPUT_TOKENS,
				compat: SHARED_COMPAT,
			},
			{
				type: "chat",
				id: "unst33r-pro",
				name: "GLM-5.3 Uncensored",
				reasoning: true,
				thinkingLevelMap: GLM_THINKING_LEVEL_MAP,
				input: ["text"],
				cost: { input: 2.5, output: 4.5, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 1_000_000,
				maxTokens: MAX_OUTPUT_TOKENS,
				compat: SHARED_COMPAT,
			},
		],
	});
}
