# Web Search (v2) — Design

## Context

v1 explicitly deferred web search/retrieval. The gap became visible when a user query needing current info ("Tell me news about Adobe today") correctly routed to Sonnet, but Sonnet had no way to actually look anything up. This spec covers adding real web search as the first v2 feature (file-attachment/RAG is a separate, later sub-project).

## Decisions

- **Search mechanism**: use each cloud provider's own native web search tool (Anthropic's and OpenAI's built-in server-side search), not a separate third-party search API. No new API key/service; billed through existing provider keys. The local model cannot search — it has no such tool.
- **Trigger**: the local router's classification pass decides, not the individual cloud model in isolation. Alongside the existing `LOCAL`/`FAST`/`ADVANCED` label, the classifier can append a `SEARCH` token (e.g. `FAST SEARCH`) when the query needs current/external info.
- **Local + search conflict**: if the classifier says `LOCAL SEARCH`, the tier is bumped to `FAST` before anything else runs — search need always forces at least a cloud tier.
- **Caps vs. search need**: usage caps (budget/call limits) still win by default — a cap-driven downgrade to `local` is not silently bypassed. But if that downgrade conflicts with a real search need, the app asks the user via a non-blocking inline banner ("This needs web search but you're over budget — Allow this one cloud call anyway?") with Allow/Deny buttons, instead of silently picking a side.
- **Offline vs. search need**: offline is a hard constraint, not a policy choice — no permission prompt, always forces local silently (unchanged from v1).
- **Citations**: shown to the user as a small collapsible "Sources" list under the message, collapsed by default.
- **Global toggle**: one on/off switch for web search, applying to the whole app (not per-conversation), surfaced as a toggle in the chat toolbar near the composer — not buried in Settings. When off, the router never sets `needsWebSearch`, regardless of query content.

## Architecture

### Kit-level changes (`AIChatRouterKit`)

- **`RoutingDecision`**: add `needsWebSearch: Bool` (default `false`).
- **`PromptedLocalQueryRouter`**: extend the classification prompt to allow an optional `SEARCH` token after the tier label; parse it into `needsWebSearch`. If the resolved tier is `.local` and `needsWebSearch` is true, bump to `.cloudFast`.
- **`RoutingCoordinator.decide()`** order of operations:
  1. Classify → raw decision (tier + needsWebSearch).
  2. If the global web-search toggle (`AppSettingsStore.loadWebSearchEnabled()`) is off, force `needsWebSearch = false` immediately — nothing downstream ever sees it as true.
  3. If `needsWebSearch` and tier is `.local`, bump to `.cloudFast`.
  4. Apply usage caps (existing `UsageLimiter.applyCaps`) — may downgrade `cloudAdvanced → cloudFast → local`.
  5. Apply offline check (existing) — may force `.local` regardless of caps.
  6. If the *cap* step (not the offline step) is what forced `.local` while `needsWebSearch` is true, mark the decision `requiresSearchPermission = true`. The tier offered for override is always `.cloudFast` specifically — the minimum viable tier for search — not whichever tier the original complexity judgment wanted (e.g. `.cloudAdvanced`). The permission ask is "let this search happen," not "restore full Advanced-tier spending"; offering the cheaper option is the more conservative reading of a budget exception. (Note: this is a deliberate divergence from the existing `downgradedFrom` field, which records the *original* pre-cascade tier for the existing downgrade-banner message — the new override-target tier is tracked separately and is always `.cloudFast`.)
- **`LLMProvider.streamCompletion`**: add a required `enableWebSearch: Bool` parameter. `LocalMLXProvider` ignores it (can't search). `AnthropicProvider`/`OpenAIProvider` attach their respective native search tool to the request when `true` — exact request/response shape to be verified empirically against the live APIs during implementation (same approach used to find and fix the earlier SSE blank-line bug), not assumed from documentation alone.
- **`ProviderStreamChunk`**: add `citations: [SearchCitation]?` (struct: `url: String`, `title: String?`), populated only on the final chunk, aggregated across the whole response — same pattern as `usage`.
- **`AppSettingsStore`**: add `loadWebSearchEnabled() -> Bool` (default `true`) / `saveWebSearchEnabled(_:)`.
- **Persistence**: add a nullable `citationsJSON` column to the `message` table (GRDB migration `v2`) storing a JSON-encoded `[SearchCitation]`, so citations survive restarts and show when scrolling history.

### App-level changes (`AIChatRouter`)

- **`ChatViewModel`**: after `routingCoordinator.decide()`, check `requiresSearchPermission`. If set, do not call any provider yet — surface the pending state (banner) and pause. `allowSearchOverride()` resumes the *original pending send* using `preDowngradeTier` with search enabled (does not re-run cap checks — that would just downgrade it again). `denySearchOverride()` proceeds with the local, non-search answer.
- **`ChatView`**: 
  - Inline Allow/Deny banner, same visual pattern as the existing routing-note/usage-warning banners.
  - Collapsible "Sources (N)" row under a message that has citations.
  - A small global toggle (globe icon) in the toolbar near the composer, backed by `AppSettingsStore.webSearchEnabled`.

## Error Handling

If a provider's search tool call fails server-side mid-stream, surface it through the existing error-banner path — never silently swallow it into an empty response (directly informed by the earlier blank-line SSE bug, where a parsing failure produced an empty message with no visible error).

## Testing

- Unit tests: router prompt parsing (tier + optional `SEARCH` token → `needsWebSearch`); `RoutingCoordinator` caps-vs-search-conflict logic using a fake router/limiter (no real network) — covers: normal search-need escalation, cap-forced-local-with-permission-flag, offline-forced-local-without-permission-flag, global-toggle-off-suppresses-flag.
- Live verification: a scratch harness (mirroring the one used for the SSE fix) hitting the real Anthropic and OpenAI search tools before wiring into the app, to confirm actual request/response shapes and citation format.

## Non-Goals (this spec)

- File attachments / RAG (separate sub-project, designed later).
- Per-conversation search toggle (global only, per decision above).
- Raising/adjusting budget caps from the permission banner (Allow only bypasses the cap for that one call).
