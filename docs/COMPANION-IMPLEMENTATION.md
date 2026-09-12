# Host-owned compaction contract

This document records the Nanocodex side of the host replacement boundary. It
does not implement a Companion or DSH retention policy, persist an application
transcript, or claim provider cache hits from scripted fixtures.

## Ownership

Nanocodex owns one model loop, typed Responses history, safe-boundary
admission, private summary generation, cancellation, provider continuation
reset, lifecycle events, structural validation, and context accounting. The
embedding host owns the replacement decision and all retention policy. In
particular, the planned DSH five-round policy does not belong in this crate.
Legacy native DSH conversation-message breakdown drift is deferred to the
planned official DSH upgrade and is not a merge-acceptance condition here.

## Rust contract

The public agent surface is:

```rust
pub trait CompactionInstructionResolver: 'static {
    fn resolve(&self, context: CompactionInstructionContext) -> CompactionInstructionFuture;
}

pub struct CompactionInstructionContext {
    pub after_model_call_index: u32,
    pub phase: CompactionPhase,
    pub trigger: CompactionTrigger,
    pub active_context_tokens: u64,
    pub auto_compact_token_limit: u64,
}

pub trait CompactionResolver: 'static {
    fn resolve(&self, context: CompactionContext) -> CompactionFuture;
}

pub struct CompactionContext {
    pub after_model_call_index: u32,
    pub phase: CompactionPhase,
    pub trigger: CompactionTrigger,
    pub active_context_tokens: u64,
    pub context_window_tokens: u64,
    pub auto_compact_token_limit: u64,
    pub history_revision: u64,
    pub operation_id: String,
    pub history: Vec<CompactionHistoryItem>,
    pub summary: String,
}

pub struct CompactionDecision {
    pub operation_id: String,
    pub history: Vec<CompactionReplacementItem>,
}
```

CompactionInstructionResolver is optional and runs before every custom summary
request admitted by the manual, automatic-pressure, overflow, or mid-turn
paths. If it is not configured, Nanocodex uses its default summary
instruction. Once configured, its non-empty result is authoritative: an
exception, cancellation, or empty result stops compaction before provider
summary dispatch and before replacement selection; Nanocodex does not silently
fall back to its default instruction. Product-specific hosts select their own
prompt through this neutral hook. For DSH integration, DSH explicitly returns
its existing Companion prompt; Nanocodex does not infer or inject it.

`CompactionReplacementItem::Original` copies a complete origin identity from
the context snapshot. `Item` carries a host-created typed Responses item.
`Summary` carries host-selected private summary text. Nanocodex materializes
the decision, validates accepted item shapes and message roles, rejects
engine-owned request-prefix duplication, verifies balanced tool calls/results,
and installs the result atomically. The operation token and origin identity
checks reject stale or foreign decisions.

The installation result exposes `installed_history`, where each item contains
the exact installed typed item and either its original identity or `None` for a
host-created item. This mapping supports filtered non-contiguous history and
zero retained original items without a contiguous-tail range abstraction.

## JavaScript contract

Node and current-isolate browser hosts expose the equivalent option:

```ts
resolveCompactionInstruction?: (
  context: CompactionInstructionContext,
  signal: AbortSignal,
) => string | PromiseLike<string>;

resolveCompaction?: (
  context: CompactionContext,
  signal: AbortSignal,
) => CompactionDecision | PromiseLike<CompactionDecision>;
```

The runtime serializes callbacks through the existing WASM host bridge and
deep-freezes callback snapshots. `resolveCompactionInstruction` is independent
of `resolveCompaction`: the former chooses the summary instruction before the
provider request, while the latter chooses installed history after the private
summary. The default browser Worker does not expose function callbacks and
rejects either resolver at runtime.

`CompactionOutcome` contains the revision, trigger, generated private summary,
installed history/provenance, and a post-install `AgentSessionContext`. The
session context and outcome both report the configured `context_window_tokens`
and the engine's current `active_context_tokens`. Cumulative billed turn usage
remains a separate accounting surface.

## Lifecycle behavior

Nanocodex first resolves a configured custom instruction, then generates one
display-suppressed private summary with the live request profile. The selected
instruction is applied on manual, automatic-pressure, overflow, and mid-turn
paths. It then captures the immutable safe-boundary history, calls an optional
post-summary replacement resolver, validates the decision, and commits the
replacement as one history revision. A pre-summary instruction exception,
abort, or empty result stops before provider dispatch. A post-summary resolver
exception, abort, invalid origin, stale operation token, unbalanced tool
history, unsupported item, or summary failure does not partially replace the
active history. A completed summary request that is not installed resets
provider continuation to a safe full-replay baseline.

Every admitted replacement operation receives a fresh opaque operation identity,
including retries after failure or cancellation. A decision cached from an
earlier operation cannot be installed on a retry, even when every replacement
item was created by the host.

Without a custom instruction or post-summary resolver, the existing provider
compaction path and its automatic engine trigger remain unchanged. No host
retention policy or five-round fallback is applied by Nanocodex.

## Verification and delivery boundary

The implementation includes native and WASM contract checks for explicit and
automatic replacement, filtered/non-contiguous and zero-original selections,
operation/origin validation, balanced tool histories, resolver failure and
cancellation, repeated replacement, context accounting, and normal turn
completion. The local release build emits Node and browser WASM bindings; the
implementation report records source revision, artifact paths, and hashes.

The repository README and AGENTS guidance were inspected. Root setup and
deployment instructions remain unchanged; this document and the JavaScript
package README are the affected integration documentation. No DSH or sibling
repository source, publication, deployment, service, or production state is
part of this implementation.
