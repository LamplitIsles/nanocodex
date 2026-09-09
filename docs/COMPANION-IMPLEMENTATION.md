# Companion engine implementation

Status: implemented on `companion-dsh-wasm`

This document records the engine-side contract delivered for the DSH Companion
embedding. It is intentionally narrower than a DSH integration acceptance
report: the DSH application, plugin lifecycle, transcript projection, recall
policy, and deployment remain in the dependent `dsh-plugins` repository.

## Ownership and public surface

Nanocodex owns the single Rust model loop used by the Node/WASM binding:
ordered turn admission, the active typed Responses history, Code Mode and
tool execution, compaction, cancellation, lifecycle events, and engine-owned
checkpoints. Companion supplies its persona through the existing
`instructions` option and its continuity policy through:

- `companionCompactionInstruction` on `Agent.create` (Node, browser, and host
  type surfaces); and
- `supplementaryContext` on `agent.turn.prompt({ input, ... })` and the native
  `PromptRequest::supplementary_context` builder seam.

The latter is a host-resolved string carried with one real input. It is
appended to that input's final user message, does not replace the persona or
start a turn on its own, and remains attached when later inputs are queued.
Recall lookup, timeouts, cancellation before admission, and DSH transcript
translation remain host responsibilities.

`historySeed` is the public Node/WASM hydration seam. It contains an active
`history` array and an optional `continuitySummary`; it is not a raw DSH event
log. The accepted typed history representations are:

- `message` items with `developer`, `user`, or `assistant` roles and supported
  `input_text`, `input_image`, `input_audio`, or `output_text` content;
- `function_call` / `function_call_output` pairs;
- `custom_tool_call` / `custom_tool_call_output` pairs; and
- existing `compaction` items with their encrypted content.

Tool outputs may be text, supported input media, or encrypted content. The
engine validates the item structure, call identities, ordering, and required
user history before a provider request. Unknown or unsupported items, an
empty/invalid summary, an empty workspace, and ambiguous `historySeed` plus
`resume` configuration fail before provider work. Historical tool calls are
history only; the engine never executes them while hydrating a session.

The engine creates the session lineage, prompt-cache key, canonical context,
and serialized snapshot metadata. A caller does not fabricate private fields
or a provider continuation ID. A seeded or resumed session starts with a
direct full replay of the selected history; it does not perform a warmup or
reuse a foreign provider continuation. The existing host-owned
`durability`/`durabilityId` store contract remains the persistence boundary.

## Companion compaction behavior

Setting `companionCompactionInstruction` opts the session into a normal
tool-free generation for all three engine compaction routes:

1. explicit `agent.session.compact()`;
2. automatic context-pressure compaction, including after a tool turn; and
3. recovery after a provider context-window overflow.

The generation receives the active model-visible history, the configured
persona/request policy, and the continuity instruction. It has no model-visible
tools and no provider continuation. The response must contain non-empty final
text and no tool calls. Nanocodex wraps the validated text in private
`<compacted-summary>` developer context, installs it with the newest coherent
tail and complete tool pairs, clears superseded provider continuation state,
and forces the next request to replay the replacement history.

Installation is transactional at the session boundary: provider failure,
invalid summary output, or cancellation leaves the previous committed history
and continuation usable. A successful compaction does not re-execute completed
tools. Agents without the option retain the existing provider compaction path.
Compaction lifecycle events use the existing model-compaction started,
completed, and failed event kinds; no DSH-specific event type was added.

## Evidence

All model-facing checks use a local scripted Responses peer or an in-process
scripted service. No paid model, DSH state, credentials, or deployment is
used.

| Contract | Evidence |
| --- | --- |
| persona replacement, QuickJS/Code Mode host tool, events, and follow-ons | generated Node/WASM `test/node.test.mjs` existing host-tool journey |
| ordinary and separately queued supplementary context | generated Node/WASM tests `Node WASM attaches supplementary context to the real prompt input` and `Node WASM preserves supplementary context on separately queued inputs` |
| successful custom compaction and failed-summary preservation through WASM | generated Node/WASM test `Node WASM uses Companion compaction for success and preserves context on failure`; the existing native `cancellation_during_pre_turn_compaction_retains_the_accepted_prompt` test covers cancellation at the same accepted-boundary seam |
| explicit automatic pressure and provider overflow route through the custom policy | native `model::recovery::companion` scripted-service tests |
| pressure during a tool turn and no repeated side effect | native `mid_tool_pressure_compacts_after_the_tool_without_rerunning_it` test; a test-owned marker is written once |
| typed text/media/tool-pair hydration, no historical execution, and validation errors | generated Node/WASM `Node WASM hydrates typed history and rejects ambiguous or unsupported seeds` |
| fresh host-owned checkpoint resume after custom compaction | generated Node/WASM `a fresh Node WASM agent resumes a host-owned Companion checkpoint` |
| public mapping and package contracts | `client.test.mjs`, TypeScript checks, package validation, and packed consumer below |

The generated WASM tests load the repository's actual `pkg-node`/WASM binding
and use only public Node exports. The packed probe extracts the actual
`nanocodex` and local `nanocodex-tools` tarballs into a test-owned directory;
it verifies context/tool dispatch, custom compaction, hydrated history, and
fresh checkpoint resume without importing the sibling DSH checkout or the
abandoned native Companion workspace.

## Reproduction checks

Run from the repository root after dependencies and the WASM target are
available:

```sh
cargo test -p nanocodex-oai-api
cargo test -p nanocodex-agent
cargo test -p nanocodex-agent --test it model::recovery::companion
corepack pnpm --filter nanocodex test:typecheck
corepack pnpm --filter nanocodex exec node --test test/node.test.mjs
corepack pnpm --filter nanocodex exec node --test test/lifecycle.test.mjs
corepack pnpm --filter nanocodex exec node --test test/*.test.mjs
corepack pnpm --filter nanocodex-vite run build:wasm
corepack pnpm --filter nanocodex check:package
corepack pnpm --filter nanocodex pack --pack-destination <test-owned-directory>
corepack pnpm --filter nanocodex-tools pack --pack-destination <test-owned-directory>
```

The packed consumer installs those two local tarballs and its declared public
dependencies into a separate temporary directory. It is keyless: the scripted
WebSocket peer supplies every response. The exact local dependency decision is
to use workspace `link:`/`file:` references or local packed tarballs during
development; neither repository requires npm publication for this engine PR.

## Checks run for this implementation

The focused native companion tests pass (3 tests), the generated Node/WASM
node suite passes (23 tests), and the API/unit suites, type checks, package
check, WASM build, tarball inspection, and corrected keyless packed consumer
probe pass. The complete package functional suite also passes (558 tests).
The package's combined `test` script reaches its performance benchmark after
those 558 tests, but exits non-zero because the existing
`a precompiled browser module instantiates once across isolated agents`
benchmark measures 2,686,976 retained linear-memory bytes against its
2,500,000-byte ceiling. A bounded fixed-point comparison built the
2259311e297e28233336262a127132a44476fff7 WASM artifact with the same
Rust/wasm-bindgen toolchain and measured the same 2,686,976 bytes after Agent
creation, so this is a pre-existing benchmark/toolchain threshold issue rather
than a Companion regression. No performance limit or unrelated memory rewrite
was made. The benchmark's other four tests pass, including the 96-turn durable
history test. The packed probe's resume and history-seed instances
intentionally start with direct generation rather than warmup; that is the
expected full-replay contract.

The implementation adds 3 native recovery tests and 2 generated Node/WASM
contract tests, in addition to the public mapping/history/compaction coverage.
The changed product/test surface is materially below the estimate in the
working spec because it reuses the existing transport, host durability, event,
QuickJS, and package-test infrastructure instead of carrying forward the
native spike's sidecar or fixture workspace.
The existing high-memory durability test was also corrected to call the
generated wasm-bindgen allocator/free exports; this is a test-harness symbol
correction, not a product memory change.

## Ticket coverage

The five implementation tickets are delivered together on this branch:

| Ticket | Delivered surface |
| --- | --- |
| 01 — context and host tool | Rust prompt admission/queue propagation, public supplementary context, generated WASM host-tool journey, and queued-input capture |
| 02 — continuity compaction | consumer-owned tool-free summary generation, explicit/pressure/overflow routing, retained-tail installation, and failure/cancellation preservation |
| 03 — history and checkpoints | engine-owned typed history seed, validation and historical-tool suppression, public replay capture, and fresh host-store resume |
| 04 — packed contract | generated artifacts, package/type checks, 558-test functional suite, local packed tarballs, and the keyless extracted consumer |
| 05 — documentation | this report and the affected package README; root entrypoint and agent-convention files remain unchanged for the reasons below |

## Boundary and non-claims

This PR does not implement or verify the DSH AgentFactory/plugin, DSH UI,
transcript event mapping, live Companion tools, real browser acceptance,
staging/prod deployment, or npm publication. The dependent adapter must prove
continuation of existing DSH conversations, one engine across its UIs, real
DSH tool dispatch, and preservation of the official DSH `0.1.2-rc.1` recovery
baseline. The engine checkpoint evidence here is a completed-boundary contract;
it does not claim arbitrary-crash exactly-once execution.

The root `README.md` and root `AGENTS.md` were inspected and intentionally
unchanged: this work adds no new user/operator entrypoint, deployment command,
agent ownership rule, or repository-wide verification convention. The
affected package API README is updated above, and this report records the
engine/DSH ownership boundary and exact checks.
