/**
 * pi-unst33r — UNST33R API provider for the pi coding agent.
 *
 * Registers https://api.unst33r.si/v1 (OpenAI Chat Completions behind a New API
 * gateway with a strict request middleware) as provider "unst33r" with a static
 * model catalog.
 *
 * Metadata sources & verification status (live-probed 2026-11-06, ~18:30 UTC):
 * - Pricing: official pricing page, catalog version 2026-10-15-launch-v1
 *   (https://unst33r.si/pricing).
 * - Context windows / max output: derived from pi's own catalog entries for the
 *   same upstream models (GLM-5.3 / GLM-5.3-Flash / DeepSeek-V4-Flash); NOT yet
 *   confirmed end-to-end through the gateway.
 * - Compatibility flags: verified against the live gateway with spaced single
 *   probes (rapid bursts trip a rate middleware that answers 503
 *   `intent_rejected` — space requests ~10s apart). Confirmed with
 *   scripts/check-compat.sh and manual probes:
 *
 *   ACCEPTED (HTTP 200):
 *   - system role; bare and with max_completion_tokens
 *   - max_completion_tokens (use this; max_tokens is REJECTED, see below)
 *   - reasoning_effort low / high / max on flash & pro (reasoning_content in
 *     non-stream responses; usage counts reasoning_tokens)
 *   - streaming WITH stream_options.include_usage=true (finish_reason and a
 *     final usage chunk verified; reasoning deltas are NOT streamed)
 *   - tool calls: ONE explicitly selected function (tool_choice) works
 *
 *   REJECTED (HTTP 503 — gateway middleware, errors alternate between
 *   `model_not_found`/"No available channel" and custom `intent_rejected`):
 *   - `max_tokens` (use max_completion_tokens instead)
 *   - streaming WITHOUT stream_options.include_usage (middleware enforces the
 *     usage requirement instead of auto-adding it as the docs claim)
 *   - `developer` role (system role required)
 *   - `temperature` / `top_p` (sampling controls)
 *   - reasoning_effort values outside the documented set (medium, and off for
 *     GLM tiers) — matches the docs' "rejected rather than silently changed"
 *   - tool requests with MULTIPLE tools / auto selection (the documented tool
 *     profile is one forced function with flat arguments at effort=low)
 *   - both max_tokens and max_completion_tokens together
 *
 *   OTHER OBSERVATIONS:
 *   - unst33r-deepseek: gateway routes the request but the upstream failed with
 *     HTTP 400 `upstream_error` during verification; streaming rejected. Treat
 *     as non-functional for now.
 *   - Burst sensitivity: >~2 requests in quick succession can trip
 *     `intent_rejected` even for valid bodies.
 *   - Output cap: max_completion_tokens is accepted up to 8192; 10240 and
 *     above are rejected (verified). Hence MAX_OUTPUT_TOKENS below.
 *   - FLAT MESSAGES REQUIRED: message content must be a plain string. The
 *     OpenAI-spec array-of-blocks form (`[{"type":"text",...}]`, which pi's
 *     openai-completions implementation sends for user messages) is rejected
 *     with 503 — verified by replaying the same payload with only the content
 *     shape changed. pi has no compat flag to force string content, so pi
 *     end-to-end calls currently fail at the gateway regardless of these
 *     flags. Nothing client-side can fix this; it needs a gateway fix (or a
 *     future pi-side message-flattening option).
 *   - Intent-style content middleware: prompt CONTENT is also classified.
 *     Short/benign prompts pass; an agent-harness system prompt combined with
 *     security-audit/exploit-hunting project instructions was rejected with
 *     the same 503 signatures, while each part in isolation passed. Expect
 *     occasional content-dependent rejections beyond the parameter rules.
 *
 * Impact on pi: metadata in this file is gateway-verified, but pi requests
 * currently fail for two server-side reasons pi cannot influence: (1) pi
 * sends array-form message content, the gateway wants plain strings; (2) pi's
 * agent loop sends multiple tools without a forced tool_choice, the gateway
 * only accepts one explicitly selected function. Chat via raw API calls with
 * string content works (verified end-to-end).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Compat flags shared by all three models (live-verified 2026-11-06):
 * - supportsStore: false            — no store / Responses API.
 * - supportsDeveloperRole: false    — VERIFIED rejected (503 intent_rejected);
 *                                     pi stays on the system role.
 * - supportsReasoningEffort: true   — VERIFIED (low/high/max accepted).
 * - supportsUsageInStreaming: true  — REQUIRED: the gateway 503s any stream
 *                                     without stream_options.include_usage.
 *                                     pi sends it when this flag is true.
 * - maxTokensField: "max_completion_tokens" — VERIFIED: `max_tokens` is
 *                                     rejected by the middleware; the
 *                                     max_completion_tokens spelling works.
 * - supportsFinishReason: default (true) — VERIFIED `stop` and `tool_calls`
 *                                     finish reasons in responses and streams.
 * - supportsStrictMode: false       — structured outputs unsupported.
 * - thinkingFormat: "openai"        — reasoning_effort is the thinking control.
 */
const SHARED_COMPAT = {
	supportsStore: false,
	supportsDeveloperRole: false,
	supportsReasoningEffort: true,
	supportsUsageInStreaming: true,
	maxTokensField: "max_completion_tokens",
	supportsStrictMode: false,
	thinkingFormat: "openai",
} as const;

/**
 * GLM-based tiers (unst33r-flash, unst33r-pro): reasoning_effort accepts
 * omitted | low | high | max (VERIFIED live). `off` and `medium` are rejected
 * by the gateway (503), so they stay unmapped (null) — pi omits the parameter
 * for unmapped levels.
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
 * DeepSeek tier additionally accepts reasoning_effort="off" per official docs
 * (live verification blocked by the tier's upstream failure on 2026-11-06).
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
 * Output cap: pi always sends max tokens in the max_completion_tokens spelling
 * (see SHARED_COMPAT). The gateway middleware VERIFIES a hard cap of 8192:
 * max_completion_tokens=8192 is accepted, 10240 and above answer 503
 * intent_rejected (this is the concrete meaning of the docs' "larger limits
 * require model-specific verification and configuration"). 8192 is therefore
 * the configured cap until the gateway raises it.
 */
const MAX_OUTPUT_TOKENS = 8192;

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
				// WARNING (2026-11-06): the gateway routes this model but its
				// upstream failed with HTTP 400 `upstream_error` during live
				// verification, and streaming is rejected (docs: non-streaming
				// text only, no tool calls). It is registered because it is part
				// of the documented catalog — do not rely on it until upstream
				// recovers; re-check with scripts/check-compat.sh --all-models.
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
