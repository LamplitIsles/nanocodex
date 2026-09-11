# Host-owned compaction contract

This document records the Nanocodex side of the host-compaction boundary. It
does not implement a Companion or DSH adapter, persist an application
transcript, or claim a provider cache hit from scripted tests.

## Ownership

Nanocodex owns one Rust model loop, typed Responses history, model/tool
execution, compaction, cancellation, lifecycle events, and engine checkpoints.
An embedding host owns persona instructions, the fixed
`companionCompactionInstruction` value when it uses one, and the optional
per-operation resolver. Nanocodex invokes the resolver and performs exactly
one summary generation; the host does not call public `session.compact()`
reentrantly or create a second agent.

## Public contract

The Rust embedding surface exports:

```rust
pub trait CompactionInstructionResolver: 'static {
    fn resolve(
        &self,
        context: CompactionInstructionContext,
    ) -> CompactionInstructionFuture;
}

pub struct CompactionInstructionContext {
    pub after_model_call_index: u32,
    pub phase: CompactionPhase,       // PreTurn | MidTurn
    pub trigger: CompactionTrigger,   // Manual | Automatic
    pub active_context_tokens: u64,
    pub auto_compact_token_limit: u64,
}

pub async fn Nanocodex::compact_with_outcome(
    &self,
) -> Result<Option<CompactionOutcome>>;
```

The Node/current-isolate `AgentOptions` equivalent is:

```ts
resolveCompactionInstruction?: (
  context: CompactionInstructionContext,
  signal: AbortSignal,
) => string | PromiseLike<string>;
```

The resolver is called before manual, automatic pressure, mid-tool, and
provider-overflow summary generation. Its result must be a non-empty string.
When configured, it supplies the instruction for that operation; a failure or
cancellation is returned to the caller and never falls back to the static
instruction. `companionCompactionInstruction` remains available for a fixed
host-owned instruction.

`agent.session.compact()` and `Actions.session.compact(agent)` return the
custom replacement below, or `null` when provider-default compaction is
active (its retention policy is not the contiguous custom range described
here):

```ts
type CompactionOutcome = Readonly<{
  revision: string;
  trigger: "manual" | "automatic";
  summary: string | null;
  replaced_history: Readonly<{ start: number; end: number }>;
  retained_tail: readonly CompactionItemIdentity[];
  context: AgentSessionContext;
}>;
```

`summary` is private and is never emitted as assistant output. The half-open
`replaced_history` range refers to the pre-replacement managed history. Each
`retained_tail` identity includes its pre-replacement index, Responses item
kind, provider/client item ID when present, and tool `call_id` when present.
`context.history` is the complete post-replacement model-visible history.
The monotonic revision and ordered result calls let a host distinguish
multiple completed replacements; no private snapshot fields or summary-text
boundary inference are required.

Automatic custom replacements do not return through the manual action. At the
safe installation boundary they emit `model.compaction.replaced` with the
same fields plus `phase` and `after_model_call_index`. Manual custom
compaction emits the event too, after `model.compaction.completed` and after
the managed history has been replaced. Each event contains the actual
post-install `context`, so repeated replacements can be projected in event
order without inspecting a snapshot.

## Generation and installation behavior

For a host-owned summary, the live request factory keeps the complete request
prefix: instructions, tool declarations and namespace metadata, model/effort
settings, prompt-cache key, and typed history. The final host instruction is
appended at the end. Eligible Responses Lite continuation and the existing
full-replay transport policy remain in use. A successful summary installation
clears the old provider continuation and makes the next ordinary request a
full replay; cache preservation is required for summary generation, not for
the post-installation request.

Summary output is validated as a non-empty generation with no code/tool
calls. Summary requests are display-suppressed, and no historical or summary
tool call is dispatched. The replacement preserves the latest real-user-led
complete tail, including completed tool call/output identities. Provider
failure, invalid output, resolver failure, or cancellation leaves the prior
usable history and continuation in place. Explicit compaction may cancel an
active turn, so embedding hosts should call it from idle maintenance.

Without either host-owned option, the existing provider compaction behavior
is unchanged. Automatic compaction remains at the engine's safe boundary and
does not invoke public host operations.

## Verification

The deterministic evidence for this PR uses only an in-process scripted
Responses service or a local scripted WebSocket peer. It includes:

- native warm continuation, context-overflow, automatic-pressure, and
  mid-tool recovery fixtures;
- native proof that a completed tool side effect occurs once and is not
  replayed by compaction;
- Node/WASM dynamic instruction selection for repeated manual operations,
  typed private outcomes, resolver failure, resolver cancellation, summary
  failure, and provider-generation cancellation;
- Node/WASM durable checkpoint resume and public history hydration;
- Rust package checks, generated WASM, JavaScript runtime/type checks, and
  package validation.

The scripted provider's `cached_tokens` values are fixture data. They are not
evidence of an actual provider cache hit. Live cached-token observation is a
separate Owner-authorized verification boundary.

The package-owned browser Worker intentionally does not support the resolver:
function values cannot cross its structured-clone boundary. Its public
options omit `resolveCompactionInstruction`, and runtime configuration rejects
one if supplied. This deliverable does not add a Worker RPC for prompt
selection.

## Repository inspection and delivery boundary

The root `README.md` was inspected and remains unchanged because this feature
does not change repository setup, deployment commands, or operator entrypoints.
The root `AGENTS.md` was inspected and remains unchanged because no agent
workflow, command convention, or ownership rule changed. The affected public
embedding documentation is [the JavaScript package README](../js/nanocodex/README.md).

No DSH or sibling repository source, deployment, publication, live provider,
benchmark, or production state is part of this deliverable. The companion
adapter may consume the public resolver and `CompactionOutcome` contract after
Owner acceptance.
