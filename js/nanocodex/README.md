# Nanocodex for JavaScript

The Node, browser, and Web API host entrypoints expose the same viem-v3-style
API. A `Transport` owns authentication, placement, and socket setup;
`Agent.create(...)` owns tools and the common Agent/Turn lifecycle. Generated
WASM handles, managed control-plane handles, and host routing remain private.

```js
import { Actions, Agent, Transport } from "nanocodex/node";

const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  model: "gpt-5.6-luna",
  instructions: "You are a Rust coding agent. Preserve unrelated work and run relevant tests.",
  reasoningMode: "pro",
  thinking: "high",
  tools,
  workspace: process.cwd(),
});

const turn = agent.turn.prompt({ input: "Build the thing." });
const result = await turn.result();
turn.dispose();
console.log(result.finalMessage);
const usage = await result.usage();
console.log(usage);
console.log(usage.estimated_cost?.usd);
console.log(usage.cost_status);

await agent.session.setThinking("high");
await agent.session.setFastMode(true);
const compaction = await agent.session.compact();
if (compaction) console.log(compaction.summary, compaction.installed_history);

const branch = await agent.session.fork({ at: result });
const branchTurn = branch.turn.prompt({ input: "Try another approach." });
const branchResult = await branchTurn.result();
branchTurn.dispose();
console.log(branchResult.finalMessage);
branchResult.dispose();

const followOn = Actions.turn.prompt(agent, { input: "Now explain it." });
const followResult = await Actions.turn.getResult(followOn);
console.log(followResult.finalMessage);
followOn.dispose();
followResult.dispose();
result.dispose();
await branch.session.shutdown();
await agent.session.shutdown();
```

### Host-selected compaction

Nanocodex owns the safe boundary, immutable history snapshot, private summary
generation, structural validation, provider continuation reset, and token
accounting. The summary instruction and replacement-history selectors are
independent. Without a custom instruction selector, Nanocodex uses its own
default compaction instruction. A host may select a custom instruction with
`resolveCompactionInstruction`; its non-empty result is applied before summary
dispatch. If that configured callback fails, is cancelled, or returns an empty
value, compaction stops before summary dispatch and does not silently use the
default. A host may separately select the complete replacement history with
`resolveCompaction`. The callback runs after the engine generated its private
summary and receives the exact history being replaced, origin identities, the
operation metadata, and both context accounting values:

```js
const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  resolveCompactionInstruction: async (context, signal) => {
    signal.throwIfAborted?.();
    return `Summarize the active context for the host's continuity surface at ${context.phase}.`;
  },
  resolveCompaction: async (context, signal) => {
    signal.throwIfAborted?.();
    const retained = context.history
      // This predicate is application policy. Nanocodex does not impose a
      // number of rounds or a contiguous-tail rule.
      .filter(({ item }) => !JSON.stringify(item).includes("discard-me"))
      .map(({ origin }) => ({ kind: "original", origin }));
    return {
      operation_id: context.operation_id,
      history: [
        { kind: "summary", text: context.summary },
        ...retained,
      ],
    };
  },
});
```

`resolveCompactionInstruction` is called for manual, automatic-pressure,
context-overflow, and mid-turn compaction. Its context is product-neutral; a
host that integrates a product-specific prompt must explicitly return that
prompt from this callback. The callback is optional and does not change the
independent `resolveCompaction` replacement contract.
For DSH integration, DSH explicitly returns its existing Companion prompt from
this selector; Nanocodex does not infer or inject product prompts.

The decision must echo `context.operation_id`. Each `original` entry must copy
an origin identity from the supplied snapshot. `item` entries may add typed
history items, and `summary` entries insert host-selected private summary text.
The engine rejects unknown origins, duplicate origins, unsupported item shapes,
duplicate engine-owned request-prefix items, and unbalanced tool calls before
mutating the active session. A resolver error, cancellation, stale decision,
or invalid decision leaves the prior history intact and forces a safe replay
baseline after any completed summary request.

The host chooses the complete replacement. It may remove items, select
non-contiguous original items, retain zero original items, and place more than
one host-created summary or history item. There is no five-round, text-only,
latest-user-tail, or other Companion retention policy in Nanocodex.

`agent.session.compact()` returns `null` for provider-default compaction. With
`resolveCompaction` it returns a `CompactionOutcome`:

```ts
type CompactionOutcome = Readonly<{
  revision: string;
  trigger: "manual" | "automatic";
  summary: string | null;
  installed_history: readonly Readonly<{
    origin: CompactionItemIdentity | null;
    item: Record<string, unknown>;
  }>[];
  context: Readonly<{
    workspace: string;
    history: readonly Record<string, unknown>[];
    context_window_tokens: number;
    active_context_tokens: number;
  }>;
}>;
```

`installed_history` is the authoritative post-install provenance mapping; it
does not assume one contiguous removed range. The same capacity and active
occupancy values are available from `agent.session.context()`. They are
estimates for the current configured context and provider usage anchors, not a
replacement for cumulative billed usage returned by a completed turn.

Compaction replacements emit the ordered `model.compaction.replaced` event
with the installed history, provenance, phase, operation boundary, and the
same post-install context accounting. The private summary never becomes an
assistant display event, and historical tool calls are never executed while
installing or resuming a snapshot.

`supplementaryContext` is host-resolved evidence appended to the same final
user message as `input`. It neither replaces persona instructions nor starts
a turn by itself, and it remains associated with its prompt while independently
queued inputs wait behind an active turn. The host owns recall, timeouts, and
its application transcript; Nanocodex only validates and carries the supplied
string.

`historySeed` is a validated engine-history entry point, not a DSH event-log
schema. Its public `HistoryItem` union accepts message text and supported
image/audio content, function and Code Mode tool call/result pairs, and
provider compaction items. `continuitySummary` is inserted as private model
context. Unknown or malformed items, an empty history without a user message,
an empty summary, and simultaneous `historySeed` plus `resume` are rejected
before provider work. Historical tool calls are replayed as history and are
never executed. The engine creates the lineage, cache key, and snapshot
metadata; callers do not fabricate provider continuation IDs.

`agent.session.snapshot()` returns the committed post-install history for cold
resume. Host-owned checkpoints use the existing `durability`/`durabilityId`
options; a fresh Agent can reopen a completed boundary and replay the installed
summary, selected history, and completed tool pairs before accepting the next
prompt. Treat snapshots, callback history, and tool payloads as sensitive model
state.

Both resolvers are available in `nanocodex/node` and the current-isolate
browser host. The package-owned browser Worker intentionally omits them because
function callbacks cannot cross its structured-clone boundary; the Worker
runtime rejects function-valued `resolveCompactionInstruction` and
`resolveCompaction` options.

DSH owns any product retention policy, including its planned five-round
policy. Legacy native DSH conversation-message breakdown drift is outside this
engine contract and is deferred to the planned official DSH upgrade.

### Current execution context and owned work

`resolveContext` is an optional current-isolate callback. Nanocodex invokes it
once when an accepted prompt reaches the model boundary, after earlier FIFO
work and any driver-owned compaction have been handled. It is not evaluated
when a prompt is merely waiting in the queue. The callback receives the stable
operation identity, selected model, resolved workspace, exact prompt, and
submitted supplementary context. It may return any combination of
`instructions`, `hostContext`, and `supplementaryContext`.

The instruction field has replacement semantics through the existing
`instructions` seam:

- If the callback omits `instructions`, Nanocodex restores the configured
  `instructions` value, or the selected naco model defaults when that option
  was omitted. Configured `additionalInstructions` remains part of that
  default path.
- A returned `instructions` string is the complete externally owned product
  replacement. Nanocodex does not append another product or coding identity.
- A returned `instructions: ""` explicitly clears the replacement. It does
  not select the naco defaults or a previous callback result.

Omitted `hostContext` and `supplementaryContext` preserve their configured or
submitted values; an explicitly empty string clears the corresponding value.
This omission-versus-empty distinction is retained for every queued turn,
warm or cold resume, model transition, and subsequent execution boundary. A
resolver error or cancellation fails before provider dispatch, without falling
back to stale or default product instructions.

Changing the effective instruction changes the provider request prefix, so the
engine resets the provider continuation and replays retained history before
the next request. The request still keeps runtime/tool protocol data separate:
the `additional_tools` prefix and Nanocodex runtime/context developer items
remain engine-owned, while the replacement developer item carries the
complete product instruction selected by the host. A context resolver does not
replace or duplicate the custom compaction instruction resolver; active
manual, automatic, and mid-turn compaction retain the current replacement, and
the next queued turn resolves its context afresh.

A downstream product assembles its own complete prompt and returns it through
this one seam, without placing product wording in Nanocodex:

```js
const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  resolveContext: async (context, signal) => {
    signal.throwIfAborted?.();
    const productPrompt = await productHost.assemblePrompt(context);
    return { instructions: productPrompt };
  },
});
```

The execution domain exposes the engine-owned reconciliation view:

```js
const current = await agent.execution.snapshot();
// current.operations: pending, active, and retained terminal identities
await agent.execution.cancel("operation-7");
// After reconnect, recover retained input without reconstructing it in the Host.
const resumed = await agent.execution.resume("operation-8");
const result = await resumed.result();
```

`execution.resume(id)` reads the retained prompt and submitted supplementary
context and goes through the same admission/effect guards as the original turn.
It returns the ordinary `Turn`. Terminal work replays its stored outcome;
unknown/pruned identities and standalone maintenance operations fail explicitly.
Resume unfinished prompts in the snapshot's acceptance order. Interrupted
external effects can still require the existing explicit recovery decision.
Cancelling an unfinished identity also works after reconnect, before resuming it.
These operations require a configured execution/durability policy; a plain
conversation snapshot does not retain an accepted queue.

Node and current-isolate callers can supply `toolProviders`. Each provider
implements `definitions()` and `resolve(name)` using one caller-owned catalog;
`resolveContext` may refresh that catalog before returning. The next request
rebuilds the complete tool profile, including tool-name mappings, and tool
execution uses the same provider. Removed tools must also disappear from
`resolve`, not just the displayed definitions. Existing in-flight tool batches
retain their admitted catalog; refresh at the execution boundary and keep
session-specific authorization in handlers when sharing providers. Provider
`close()` participates in host cleanup. The package Worker rejects these
function-bearing providers; construct them inside the execution isolate.

The snapshot is bounded: every unfinished operation is included, while only
the newest retained terminal receipts are included. `truncated` marks an older
terminal reconciliation window. Subscribe to `execution.state` before reading
the initial snapshot, and use each notification to request a fresh snapshot.
Serialize these reads before updating the display; do not apply a buffered
notification's status over a newer snapshot. This closes the subscription/read
race using the existing event watcher and authoritative query. `revision` is the
durable storage revision, not an activity sequence. JSON `revision` and
`accepted_order` are canonical decimal strings so all u64 values survive JavaScript;
preserve the returned order or compare using `BigInt`, not `Number`. Thus, pending and active can share
a revision. Reconnect with a new subscription and fresh snapshot. Durable
acceptance is committed before `turn.accepted()` resolves; a store error is
reported instead of acknowledging uncommitted work. Unfinished effects after a
crash remain subject to the durability recovery/ambiguity rules documented by
the Rust durability layer.

The current implementation preserves existing staging data. It does not
perform automatic migration or keep long-lived compatibility reads for the new
execution contract. Durable prompt inputs now retain a prompt/context envelope; existing stored inputs need the separately approved cutover. A separate one-time migration proposal, including backup,
verification, and rollback steps, must be approved before any deployment that
needs to transform existing durable state. Migration and deployment are outside
this SDK implementation boundary.

Transports are explicit, immutable configurations, like viem v3 transports:

```js
Transport.openAi({ apiKey, websocketUrl });
Transport.chatGpt({ subscription });
Transport.mpp({ session: paymentSession });
Transport.managed({ agent: { create: true } });
Transport.managed({ agent: { id: retainedAgentId } });
```

For `nanocodex/node`, `Transport.openAi` and `Transport.chatGpt` prefer the
Responses WebSocket. Set `apiBaseUrl` to the matching HTTPS `/v1` base when
the WebSocket endpoint is not guaranteed to be reachable. A failed upgrade or
other eligible transport failure before response output begins is replayed
once over that endpoint as an incremental `text/event-stream` request. The
Node host caps WebSocket establishment and HTTP response headers at 15 seconds,
owns the fetch reader and bearer headers, and keeps the selected HTTPS
transport for the rest of that live Agent session. The request body, session
ID, thread ID, tool results, and authoritative history remain engine-owned;
the host never needs to resubmit a turn after output has started.

Fallback is deliberately not used for authentication, model/request
validation, caller cancellation, or a failure after an assistant delta,
response item, or tool execution has begun. The browser/current-isolate and
MPP hosts do not advertise this Node-only host capability. When fallback is
selected, `agent.events.watch()` receives one sanitized
`model.attempt.retrying` event whose payload includes:
`previous_transport: "responses_websocket_v2"`,
`next_transport: "responses_https_sse"`, and a low-cardinality `reason` such
as `"upgrade_required"` or `"transport_unavailable"`; it contains no bearer
token, headers, prompt, or request body.

Managed identity is always explicit. `{ create: true }` provisions one new
account-owned durable Agent; `{ id }` eagerly verifies and opens that existing
Agent. Omitting `agent` never creates a durable resource. Both return the same
`sessionId`, `events.watch()`, `turn.prompt()` / Turn, `dispose()`, and
`session.shutdown()` lifecycle used by local transports. Managed shutdown
closes this client and any reverse tool attachment; it does not delete the
durable Agent.

Choose the entrypoint by execution owner:

- `nanocodex/browser` creates and owns a package module Worker. Its options are
  structured-clone-safe and its default harness includes the browser workspace.
- `nanocodex/host` runs in the current Web API isolate. Use it inside a
  caller-owned browser Worker, Cloudflare Worker, Vercel Function, or similar
  host when transports, tools, filesystems, or durability contain functions.
- `nanocodex/node` runs in the current Node process with Node host adapters.

The browser transports additionally expose `Transport.hostManaged(...)` for a
Worker, Durable Object, or application proxy that owns rotating credentials.
Authentication modes are constructors rather than a union of mutually
exclusive fields on `Agent.create`.

### Compose and place tools

`createTools` owns one deterministic tool recipe. Custom functions, a portable
workspace, and MCP are composed once; placement is selected afterward. Pass the
recipe to an in-process Node or Web API host, or reverse-attach it to a managed
agent target:

For a reverse machine attachment, `attachmentId` is its stable safe-ASCII source
identity (at most 123 bytes), and must equal the `id` of its sole non-secret
`machines` entry. Multiple machines may stay attached through independent
`Tools` runtimes; reconnect one runtime to replace that machine route while the
durable managed agent stays alive. Generic attachments may omit machine metadata.

```js
import { createTools } from "nanocodex";
import { Agent, Transport, Workspace } from "nanocodex/node";
import WebSocket from "ws";

const workspace = await Workspace.open({ path: process.cwd() });
const tools = await createTools({
  attachmentId: "laptop",
  machines: [{
    id: "laptop",
    name: "My laptop",
    workspace: process.cwd(),
    capabilities: ["filesystem", "native-shell"],
  }],
  workspace,
  tools: {
    lookup_issue: {
      description: "Read one issue from the application database.",
      parameters: {
        type: "object",
        properties: { id: { type: "string" } },
        required: ["id"],
        additionalProperties: false,
      },
      handler: ({ id }) => issues.get(id),
    },
  },
  mcp: {
    docs: { url: "https://mcp.example.test" },
  },
});

const agent = await Agent.create({
  transport: Transport.managed({
    agent: { id: agentId },
    baseUrl: managedOrigin,
    apiKey,
    toolsTransport: (target, options) => new WebSocket(target, {
      headers: options.headers,
    }),
  }),
  tools,
});

// On shutdown:
await agent.session.shutdown();
```

The managed target retains credentials in a private transport closure; the API
key is not embedded in the endpoint or serializable target data. While the
attachment is live, an exact same-name attached tool wins over the cloud tool.
After detach, the cloud definition is immediately eligible again. Definition
parity is validated before the attached catalog becomes active, and calls
already admitted retain their pinned placement.

`Tools` has one Agent owner and owns the lifecycle of its MCP runtime and
reverse attachments. Local transports host the recipe in process; a managed
transport starts a bounded reverse-attachment supervisor while the durable
Agent remains available through its cloud tools. A successful catalog
acknowledgement upgrades later admissions to the attached placement. A second
Agent host rejects the same value. Do not also supply legacy top-level
workspace or MCP configuration to an Agent that already receives them through
`Tools`.

Browser consumers can attach Codex's ChatGPT Realtime voice lifecycle to the
same retained Agent. The resource owns microphone, speaker, WebRTC, sideband,
and delegation cleanup; stopping voice does not cancel an active coding turn.
Snapshots update each speaker's transcript row as speech arrives, using a stable
`id` and `isPartial` flag. Completion replaces that row. `transcript.delta` events
carry the current partial text; `transcript` events retain completed-turn semantics.
Internal Realtime envelopes are projected into spoken text before publication.
Transcript updates continue while a delegation waits for durable admission.

The one-operation-at-a-time action surface is the canonical imperative API:

```js
import { Actions } from "nanocodex/browser";

const voice = Actions.voice.create(agent);

await Actions.voice.start(voice); // defaults to Codex's `cove` voice
await Actions.voice.stop(voice);
await Actions.voice.destroy(voice);
```

Subscription voice preferences use the same Rust policy in browsers and native
apps. `start` and `create` accept `voice`, `instructions`, `pace` (`slow`,
`natural`, `fast`), `updates` (`auto`, `results`, `silent`), and optional
`acknowledgements`. Pace and style are speaking instructions. Update preferences
also select how coding-agent commentary and results reach the voice model.
Advanced consumers can set `handoffMode` to `thinking`, `commentary`, or
`bem_tags`; an explicit `updates` preference takes precedence. Apply changed
settings by stopping and starting a call. The shared terminal provides a saved
Voice settings panel with an Apply and reconnect action.

During an active call, `Actions.voice.speak(voice, text)` queues explicit speech,
`appendText(voice, text, { role: "developer" })` adds text using Codex's
subscription adapter (which treats all roles as context), and
`appendContext(voice, text)` adds background commentary without
requesting speech. Context and speech are split into provider-sized messages.
These commands retain frames until sent and preserve them
across a sideband reconnect. They are also methods on the resource and on
`useVoice` from `nanocodex-react`. These settings use ChatGPT subscription voice;
custom voices and Platform audio configuration are not accepted.

`Voice.create(...)` remains the equivalent namespaced resource constructor, and
`Voice.voices` is the exact ChatGPT V3 voice catalog. The constructor accepts a
normal browser Agent, an account-owned managed Agent, or a grant-scoped
`ConnectAgent`. Authentication stays in the owning host routes; Connect uses a
fresh one-use sideband ticket, and the browser binding never receives ChatGPT
credentials or places its reusable grant bearer in a WebSocket URL.

### Durable Cloudflare Agent

`nanocodex/cloudflare` is the standard Durable Object consumer. It keeps the
host transport, SQLite durable state, private runtime identity, event persistence,
hibernatable socket fan-out, and cursor replay inside the adapter:

```js
import { DurableObject } from "cloudflare:workers";
import { Agent } from "nanocodex/cloudflare";

export class CodingAgent extends DurableObject {
  #ready;

  constructor(context, env) {
    super(context, env);
    this.#ready = Agent.create(this, {
      instructions: "You are a focused coding agent.",
    });
  }

  async prompt(input) {
    const agent = await this.#ready;
    const turn = agent.turn.prompt({ input });
    let result;
    try {
      result = await turn.result();
      return result.finalMessage;
    } finally {
      try {
        result?.dispose();
      } finally {
        turn.dispose();
      }
    }
  }

  async fetch(request) {
    return (await this.#ready).events.connect(request);
  }
}
```

The returned value is the normal typed Agent: follow-on prompts reuse its owned
history, and results remain independently awaitable. `events.connect(request)`
is only a read-only AgentEvent WebSocket surface; it does not define prompt,
membership, room, quota, or application routing policy. Event frames are
`{ cursor, event }`. Replay is bounded; a far-behind client can receive
`{ type: "replay_paused", cursor, latest_cursor }` followed by close code
`1013`, then continues by reconnecting with that pause cursor as
`?cursor=<decimal>`.

Cloudflare Agents default to direct tool mode because Workers prohibit dynamic
`eval`/`new Function`. Caller-defined tools therefore work without a code
evaluator. Select `toolMode: "code"` only when also supplying an evaluator that
is explicitly compatible with the deployed Worker runtime. Runtime-owned
Subagents are installed by default, including on a durable root. Clean children
persist independent execution state under their own agent session IDs. The
Rust task-tree registry remains in memory and is closed with the live root, so
tree-local IDs and topology are not reconstructed from those agent states. Use
`Subagents.create({ maxConcurrency })` in `tools` to set an explicit finite
concurrency limit. Active subagent turns are unlimited by default.

Each Durable Object persists a private runtime identity in its own SQLite
storage and derives its state identity from it, so multiple objects in one
isolate remain independent and eviction reuses the same identity. Before
replacing an Agent inside a still-live object, await `agent.session.shutdown()`;
deleting the Durable Object and its retained event/state rows remains an
application-owned lifecycle operation.

Internally this constructor uses `Transport.hostManaged` and an exact brokered
Responses WebSocket. `authMode` is required and accepts only `"api_key"` or
`"chatgpt"`; URLs and non-secret placeholders are fixed. `Agent.create` awaits
the private binding's WebSocket upgrade, so a missing binding or a broker whose
single policy does not match the selected mode rejects startup. The managed
Worker API deliberately has no provider-key, token, transport, or durability
option.

The managed Worker needs only the Durable Object and private broker bindings;
the broker's separate Wrangler configuration owns the real provider secret:

```jsonc
{
  "services": [{ "binding": "EGRESS", "service": "my-private-egress-broker" }],
  "durable_objects": {
    "bindings": [{ "name": "AGENTS", "class_name": "CodingAgent" }]
  },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["CodingAgent"] }],
  "vars": { "NANOCODEX_AUTH_MODE": "chatgpt" }
}
```

Do not put `OPENAI_API_KEY`, OAuth material, account IDs, or relay capabilities
in this managed Worker configuration. A private Service Binding is a
controlled-code boundary, so the separately deployed broker must still enforce
one exact destination, one matching credential policy, placeholder replacement,
header allowlisting, and no public route.

Task-tree orchestration is an optional extension over the core agent. Both
native and WASM consumers run the same Rust implementation and receive the
same seven tools: `spawn_agent`, `submit_result`, `send_agent_message`,
`list_agents`, `wait_agent`, `interrupt_agent`, and `close_agent`.

Inside a caller-owned Worker or server isolate, host capabilities stay as
ordinary functions without crossing another compatibility protocol:

```js
import { Agent, Transport } from "nanocodex/host";
import nanocodexWasm from "./nanocodex.wasm";

const myApplicationTool = {
  name: "lookup_order",
  description: "Look up one order.",
  parameters: {
    type: "object",
    properties: { id: { type: "string" } },
    required: ["id"],
    additionalProperties: false,
  },
  handler: ({ id }) => orders.get(id),
};

const agent = await Agent.create({
  module: nanocodexWasm,
  transport: Transport.hostManaged({
    websocketUrl: "/api/responses",
    createWebSocket: (endpoint) => new WebSocket(endpoint),
  }),
  tools: [myApplicationTool],
});
```

`parameters` is optional and defaults to an open object. TypeScript types are
erased at runtime, so provide JSON Schema only when the model needs a precise
argument contract, as `lookup_order` does above.

For provider-native free-form input, set `definition` on the same application
tool. The router replaces `definition.name` with the containing map key (or
the `NamedTool.name`), so the host does not need a second tool-registration
path. A custom definition receives the exact model string in its handler and
the normal `ToolContext` identity and cancellation signal:

```js
const applyPatch = {
  description: "Apply one patch through the host-owned workspace.",
  definition: {
    type: "custom",
    description: "Apply one patch through the host-owned workspace.",
    format: {
      type: "grammar",
      syntax: "lark",
      definition: 'start: "patch"', // replace with the host's complete grammar
    },
  },
  async handler(input, { callId, sessionId, signal }) {
    if (typeof input !== "string") throw new TypeError("raw patch input required");
    return applyPatchInHost(input, { callId, sessionId, signal });
  },
};

const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  tools: { apply_patch: applyPatch },
  subagents: false,
});
```

`type: "custom"` is a direct Responses custom tool, so its handler input is a
string rather than parsed JSON. Completed custom calls and outputs remain
engine-owned history: snapshots and cold `resume` replay them as model context
without invoking the handler again. Node agents enable built-in subagents by
default; `subagents: false` removes those built-in tools while retaining the
application tools above. Passing `Subagents.create()` together with `false`
is rejected.

## Standard web and browser tools

`nanocodex/tools` contains composable named tools rather than another agent or
runtime. Each factory returns an entry that can sit beside application tools
and Rust/WASM extensions in the same array:

```js
import { Agent, Transport } from "nanocodex/host";
import {
  dataset,
  imageGeneration,
  updatePlan,
  web,
} from "nanocodex/tools";

const agent = await Agent.create({
  transport: Transport.hostManaged({
    websocketUrl: "/api/responses",
    createWebSocket: (endpoint) => new WebSocket(endpoint),
  }),
  tools: [
    web(),
    dataset(),
    imageGeneration({
      recentImages: (sessionId, count) => images.get(sessionId).slice(-count),
      rememberImage: (sessionId, imageUrl) => images.get(sessionId).push(imageUrl),
    }),
    updatePlan(),
    myApplicationTool,
  ],
});
```

The web and image factories use the canonical OpenAI/Codex tool names, argument
schemas, bounds, and image-edit modes, and normalize common malformed model
arguments before dispatch. In a browser, they default to the same-origin
`/api/tools/web-search` and `/api/tools/image-generation` routes. The host owns
only a bounded JSON endpoint, credentials, authorization, and persistence.
`web(...)` posts `{ commands, session_id, model }`, where `model` is the
effective model of the invoking root or subagent; `imageGeneration(...)` posts
`{ images, prompt }`. The host owns model authorization and may ignore or
override this value. Pass `url` when the host route lives elsewhere.

`dataset()` runs entirely in the caller and inspects public HTTPS Parquet,
uncompressed JSONL, and Hugging Face datasets. It opens a session-scoped handle,
returns schema metadata, and supports projection and filtering queries without
hard row or offset ceilings. Input and output bytes remain bounded; partial
results return an opaque `nextCursor` that retains the query and resumes from a
physical Parquet row batch or JSONL byte position. Parquet uses HTTP range reads
and predicate pushdown where possible; JSONL scans incrementally and requires
byte-range support for cursor continuation. The implementation, Parquet reader,
and non-Snappy codecs load only after the model first calls the tool. Direct URLs
must allow browser CORS, and Parquet servers must support byte ranges.
Consumers that only need this capability can import `dataset` from the smaller
`nanocodex/tools/dataset` leaf entry.

```js
const datasets = dataset();
const opened = await datasets.handler({
  operation: "open",
  source: {
    kind: "huggingface",
    dataset: "openai/gsm8k",
    config: "main",
    split: "train",
  },
}, { sessionId: "thread-1" });

const page = await datasets.handler({
  operation: "query",
  dataset_id: opened.datasetId,
  columns: ["question", "answer"],
  filters: [{ column: "question", op: "contains", value: "how many" }],
  limit: 5,
}, { sessionId: "thread-1" });

if (page.nextCursor) {
  await datasets.handler({
    operation: "query",
    dataset_id: opened.datasetId,
    cursor: page.nextCursor,
    limit: 5,
  }, { sessionId: "thread-1" });
}
```

This same adapter works inside a Cloudflare Worker or Durable Object:

```js
import { Agent, Transport } from "nanocodex/host";
import { web } from "nanocodex/tools";

const agent = await Agent.create({
  module: env.NANOCODEX_WASM,
  transport: Transport.hostManaged({
    websocketUrl: env.RESPONSES_WEBSOCKET_URL,
    createWebSocket: (endpoint) => new WebSocket(endpoint),
  }),
  toolMode: "direct",
  tools: [
    web({
      url: env.WEB_TOOL_URL,
      headers: { authorization: `Bearer ${env.WEB_TOOL_TOKEN}` },
    }),
  ],
});
```

For a caller-owned browser Worker, `browser(...)` composes the same tools with
one persistent OPFS workspace and a lazy WASM-backed shell (Python through
Pyodide, C/C++ through wasm-clang, plus browser Git and bounded commands):

```js
import { Agent } from "nanocodex/host";
import { browser } from "nanocodex/tools/browser";

const runtime = await browser({
  threadId,
  recentImages,
  rememberImage,
});

const agent = await Agent.create({
  transport,
  filesystem: runtime.filesystem,
  instructions: runtime.instructions,
  executionEnvironment: {
    currentDate,
    timezone,
    projectInstructions: runtime.projectInstructions,
  },
  tools: runtime.tools,
});
```

`browser(...)` runs in a browser Worker because OPFS is a browser capability;
use the individual factories in server-side Cloudflare Workers. Vite integration
is provided separately by `nanocodex-vite`.

The browser composition includes native `browseX` public X browsing, advertised
by `accountInfo().apis` without an X connector. The embedding app serves
`/api/tools/x/browse` and `/api/tools/x/convert`; Nanocodex's account app forwards
these requests to the private X Worker.

The browser composition includes `render_artifact` as a normal typed tool. For
other hosts, compose the same factory with any workspace implementing the
Nanocodex workspace contract:

```js
import { artifact, web } from "nanocodex/tools";

const tools = [
  web({ url: env.WEB_TOOL_URL }),
  artifact({ workspace }),
];
```

The artifact factory performs no dynamic evaluation and is safe to load in a
Cloudflare Worker. Browser hosts additionally install the exact iframe syntax
validator. The model calls `tools.render_artifact({ id, title, source })` from
Code Mode, or `render_artifact` directly when the host selects direct mode; no
artifact CLI is installed. Artifact capacity is host-owned: the binding adds no
byte, source-length, ID-length, or document-count policy limits.

Application tools may provide `outputSchema` alongside `parameters`. The
binding serializes it to Rust's `output_schema`, so Code Mode receives the same
generated TypeScript return declaration as native Codex tools instead of
guessing result fields:

```js
const execCommand = {
  name: "exec_command",
  description: "Run a command.",
  parameters: { type: "object", properties: { cmd: { type: "string" } }, required: ["cmd"] },
  outputSchema: {
    type: "object",
    properties: { output: { type: "string" }, wall_time_seconds: { type: "number" } },
    required: ["output", "wall_time_seconds"],
    additionalProperties: false,
  },
  handler: runCommand,
};
```

This is what loading a Rust-written tool from JavaScript looks like here.
`nanocodex-subagents` is statically linked into `nanocodex.wasm`; every JS
`Agent.create(...)` installs it by default. Spreading `Subagents.create()` into
`tools` overrides its maximum concurrency and contributes one opaque extension
entry, not seven JavaScript handlers. Inside the binding, Rust creates one
shared registry and installs fresh tools for every root, spawn, and fork:

```rust,ignore
let (registry, control, updates) = nanocodex_subagents::channel(max_concurrency);
let tools = Tools::builder().without_defaults().build()?;
let tools = nanocodex_tools::embedded::bind_host(tools, javascript_host);
let (agent, events) = Nanocodex::builder(openai)
    .tools_factory(move |handle| {
        nanocodex_subagents::install_tools(tools.clone(), handle, registry.clone())
    })
    .build()?;
```

This is deliberately static composition, not a generic runtime loader for an
arbitrary second `.wasm` plugin. A custom Rust extension is linked into the
binding crate at build time and exposed by a small branded JS configuration;
adding a dynamic component ABI would be a separate feature with a much larger
contract and runtime cost.

The root owns the task tree. `agent.session.shutdown()` closes every child
before stopping the root driver; applications do not maintain a parallel JS
scheduler or reimplement the communication tools.

## Persistent workspaces

Runtime-specific `Workspace` adapters give an embedding application one file
contract for both local browser kernels and Node kernels. The browser adapter
uses the origin-private file system (OPFS), so reopening the same stable name
after a Worker, page, or agent-session restart reuses its files. The Node
adapter roots the same operations in an ordinary directory and refuses path
traversal and symbolic-link escapes.

```js
import { Workspace } from "nanocodex/browser/workspace";
import { Agent, Transport } from "nanocodex/host";

const workspace = await Workspace.open({ name: "my-notebook" });
const agent = await Agent.create({
  transport: Transport.hostManaged({
    websocketUrl: "/api/responses",
    createWebSocket: (endpoint) => new WebSocket(endpoint),
  }),
  filesystem: workspace,
});

await workspace.writeFile("README.md", "# Durable browser workspace\n");
console.log(await workspace.list(".", { recursive: true }));
```

The returned handle is application-owned and remains usable by a file browser,
editor, upload/download surface, or another agent session. `Workspace.tools`
exposes bounded `list_files`, `read_file`, `write_file`, `make_directory`, and
`delete_file` operations through the normal caller-defined tool boundary. It
does not add a fake browser shell.

Node uses the same shape with a real directory:

```js
import { Agent, Transport, Workspace } from "nanocodex/node";

const workspace = await Workspace.open({ path: process.cwd() });
const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  filesystem: workspace,
});
```

Node and browser applications can instead pay through MPP without an OpenAI
API key. Pass an MPP session with a `ws(endpoint)` method; an `mppx` Tempo
session manager has this shape. Nanocodex defaults the socket to
`wss://openai.mpp.tempo.xyz/v1/responses` when `mpp` is present.

```js
import { Agent, createTempoProviderFromAccounts, Transport } from "nanocodex/node";
import { Expiry } from "accounts";
import { Provider } from "accounts/cli";
import { parseUnits } from "viem";
import { connect } from "viem/experimental/erc7846";
import WebSocket from "ws";

const pathUsd = "0x20c0000000000000000000000000000000000000";
const provider = Provider.create({ mpp: false });
if (!provider.store.persist.hasHydrated()) {
  await new Promise((resolve) => provider.store.persist.onFinishHydration(resolve));
}
const status = await provider.getAccessKeyStatus();
if (status === "missing" || status === "expired") {
  await connect(provider.getClient(), {
    capabilities: { authorizeAccessKey: {
      expiry: Expiry.days(1),
      limits: [{ token: pathUsd, limit: parseUnits("25", 6) }],
    } },
  });
}
const root = provider.getAccount();
const account = await provider.store.accessKeys.select({
  account: root.address,
  chainId: provider.getClient().chain.id,
});
if (!account) throw new Error("Tempo account has no usable access key");
console.error(`Tempo access-key signer: ${account.accessKeyAddress}`);
const tempoProvider = await createTempoProviderFromAccounts({
  wallet: provider,
  accessKey: account.accessKeyAddress,
  policy: {
    autoSwap: { tokenIn: [pathUsd], slippage: 1 },
    maxDeposit: "0.05",
    topUpAmount: "0.05",
  },
  session: { bootstrap: true, webSocket: WebSocket },
});
const mpp = tempoProvider.session;

const agent = await Agent.create({
  transport: Transport.mpp({ session: tempoProvider }),
  thinking: "none",
  fastMode: true,
  tools,
});
const events = agent.events.watch();
const unwatch = events.onEvent((event) => {
  process.stdout.write(`${JSON.stringify(event)}\n`);
});
let turn;
let result;
try {
  turn = agent.turn.prompt({ input: "Build the thing." });
  result = await turn.result();
  console.error(result.finalMessage);
} finally {
  try {
    result?.dispose();
  } finally {
    turn?.dispose();
  }
  unwatch();
  events.off();
  const cleanupErrors = [];
  try {
    await agent.session.shutdown();
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    await mpp.close();
  } catch (error) {
    cleanupErrors.push(error);
  }
  if (cleanupErrors.length === 1) throw cleanupErrors[0];
  if (cleanupErrors.length > 1) {
    throw new AggregateError(cleanupErrors, "agent shutdown and MPP settlement both failed");
  }
}
```

The application still owns its wallet, deposit policy, persisted payment
channel store, and final settlement. Keep the manager alive to reuse its channel
across agents, and supply mppx `channelStore` for reuse after a process or page
restart. Nanocodex never closes a caller-owned MPP session.
`createTempoProviderFromAccounts({ wallet, ... })`
accepts any provider returned by Accounts SDK `Provider.create(...)`, regardless
of its wallet adapter, and constructs both payment paths from that provider's
adapter-neutral `getMppxParameters()` contract. The lower-level
`createTempoProvider({ session, payment })` remains available when the
application constructs MPPx itself. Both explicitly select Tempo provider mode.
In that mode Nanocodex automatically adds its built-in Mercator MCP and wraps it
with the same wallet and payment policy. The provider also exposes an MPP-aware
`fetch`; Mercator's paid REST handoffs use that same method rather than a second
wallet or payment configuration. Its MCP transport remains wrapped at the MCP
protocol layer, so browser requests do not need an `Accept-Payment` CORS header.
Browser Connect consumers send paid REST handoffs through the Connect API's
fixed Mercator relay because Mercator's job endpoint is not itself CORS-enabled;
the relay preserves MPP challenges, credentials, and receipts but never signs.
Passing a generic `MppSession`, an OpenAI key, or ChatGPT host auth does not
initialize Mercator. Pass `mcp: false` to opt out explicitly.

Remote Streamable HTTP MCP servers are configured directly on the agent. The
JavaScript binding uses the official MCP SDK transport, keeps remote tools
deferred, and mirrors native Nanocodex exposure: the initial Responses request
contains provider-native `tool_search`, while canonical `mcp__<server>__<tool>`
functions are callable only below Code Mode. Code Mode also exposes
`tools.tool_search`, so one cell can discover a deferred tool and invoke the
returned canonical name. Search results return loadable namespaces for the next
model request; remote tools never become a flat set of top-level model-visible
calls.

MPP-enabled MCP uses MPPx's in-place `McpClient.wrap`. Ordinary paid HTTP uses
`Mppx.create(...).fetch`. The public `tempo()` method is installed in both and
supports Tempo charge and session challenges, so paid services composed behind
Mercator use the same signer and spending policy as the model:

```js
const mcpMethod = tempo({
  account,
  channelStore,
  getClient: () => provider.getClient(),
  maxDeposit: "0.05",
  topUpAmount: "0.05",
});

const agent = await Agent.create({
  transport: Transport.mpp({
    session: createTempoProvider({
      session: mpp,
      payment: { methods: [mcpMethod] },
    }),
  }),
});
```

Explicit `mcp` entries are merged over the Tempo defaults, so an application
can replace `mercator` or add other servers without rebuilding the provider.

Each server also accepts `headers`, `fetch`, allow/deny tool lists, a timeout,
or an already initialized MCP SDK-compatible `client`. Nanocodex closes clients
it creates and leaves caller-owned clients open. Connection failures are
reported by `tool_search` so one unavailable server does not prevent the agent
from starting.

Code Mode is the default. Model-facing `exec` cells can yield with a first-line
`// @exec: {"yield_time_ms": 1000, "max_output_tokens": 1000}` directive or
`yield_control()`. The model resumes the returned cell ID through `wait`, which
returns only new output and can terminate the cell. Cells belong to their agent
session and are invalidated when the host shuts down; a persisted `wait` never
restarts missing work. Embedded cells retain ownership of all nested tool calls
until they finish or are cancelled.

Custom evaluators receive `audio`, `notify`, `yield_control`, `setTimeout`, and
`clearTimeout` alongside the existing globals in `CodeEvaluatorEnvironment`.
Forward those helpers into the guest environment to preserve the model-visible
contract. `image` accepts individual MCP image blocks and honors explicit detail
before MCP metadata; `audio` accepts MCP audio blocks. Both accept data URLs.

Runtimes whose content-security policy rejects `eval`/`new Function` can supply
a Code Mode evaluator. `createQuickJsEvaluator` accepts an asyncified
`quickjs-emscripten-core` module, serializes Asyncify execution, and exposes only
the standard Nanocodex Code Mode globals across the interpreter boundary. This
keeps deferred MCP plus Code Mode functional in Cloudflare Workers:

```js
import asyncVariant from "@jitl/quickjs-wasmfile-release-asyncify";
import { Agent, createQuickJsEvaluator, createTempoProvider, Transport } from "nanocodex/host";
import { newQuickJSAsyncWASMModuleFromVariant } from "quickjs-emscripten-core";

const quickJs = await newQuickJSAsyncWASMModuleFromVariant(asyncVariant);
const agent = await Agent.create({
  transport: Transport.mpp({ session: tempoProvider }),
  // module and mcp omitted here
  codeEvaluator: createQuickJsEvaluator(quickJs),
});
```

Cloudflare requires the QuickJS `.wasm` file to be statically imported and
passed with `newVariant(..., { wasmModule })`; the complete deployment is in
`examples/cloudflare-fetch-mcp`.

Completed results can be persisted and resumed by a fresh Node or browser
agent:

```js
const snapshot = await result.snapshot();
result.dispose();
await agent.session.shutdown();

const resumed = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  resume: snapshot,
  tools,
});
await resumed.session.shutdown();
```

The snapshot contains authoritative typed history but no provider response ID,
so the first resumed request safely replays the committed conversation. Resume
with the same instructions and tool definitions, and release the original
agent before handing its snapshot to another writer.

For crash recovery inside a turn, provide the generic durability host instead
of manually persisting snapshots. The host stores one opaque Rust state value;
model replay, tool ambiguity, operation deduplication, and checkpoint recovery
remain in Rust/WASM:

```js
import { Agent, Transport } from "nanocodex/host";

const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  durability: {
    async load(stateId) {
      return database.loadState(stateId);
    },
    async acquire(stateId, { ownerId }) {
      return database.acquireState(stateId, ownerId);
    },
    async replace(stateId, { ownerId, fence, expectedRevision, payload }) {
      return database.compareAndReplace(
        stateId,
        ownerId,
        fence,
        expectedRevision,
        payload,
      );
      // { status: "replaced", revision: "8" }
      // or { status: "conflict", actualRevision: "8" }
      // or { status: "not_committed", message: "transaction rolled back" }
    },
  },
  durabilityId: "customer-agent-123",
});

// Every prompt is durable because the state store is configured. Supply `id`
// only when an external retry must identify the same logical operation.
const turn = agent.turn.prompt({ input: "Build the thing." });
// const turn = agent.turn.prompt({ id: "request-7", input: "Build the thing." });
let result;
try {
  result = await turn.result();
  console.log(result.finalMessage);
} finally {
  try {
    result?.dispose();
  } finally {
    turn.dispose();
    await agent.session.shutdown();
  }
}
```

Revisions are unsigned decimal strings so JavaScript preserves Rust's full
`u64` range. Import `durabilityRevision`, `createMemoryDurabilityStore`,
`createSqliteDurabilityStore`, and `sqliteDurabilitySchema` from the small
`nanocodex/durability` leaf. Durable step hosts can carry the memory store's
`snapshot()` into the next step. SQLite hosts provide one transaction query
adapter and execute the canonical schema; the platform never interprets the
opaque Rust state. See `js/managed`,
`examples/vercel-workflows`, and `examples/rivet-actors` for all three host
shapes.

Cloudflare Durable Objects can bind their colocated SQLite and initialize the
canonical schema in one call. The adapter is structural and adds no Workers
runtime dependency:

```js
import { createCloudflareDurabilityStore } from "nanocodex/durability/cloudflare";

const durability = createCloudflareDurabilityStore(this.ctx.storage);
const agent = await Agent.create({
  module: env.NANOCODEX_WASM,
  transport,
  durability,
  durabilityId: sessionId,
});
```

Vercel and other PostgreSQL hosts use `createPostgresDurabilityStore(pool)`
from `nanocodex/durability/postgres`; connection ownership and secret policy
remain in the application.

The built-in stores can move one stopped agent across providers without
decoding or rebasing its Rust state. Cloudflare owners should use the adapter's
lifecycle-safe export instead of reconstructing its private state ID:

```js
import { Agent as CloudflareAgent } from "nanocodex/cloudflare";
import { importDurabilityStatePages } from "nanocodex/durability";
import { createPostgresDurabilityStore } from "nanocodex/durability/postgres";

await cloudflareAgent.session.shutdown();
const pages = [];
let cursor;
let to;
do {
  const page = await CloudflareAgent.exportDurabilityState(durableObjectOwner, {
    from: "0", // exclusive destination revision
    to,        // omit once, then repeat the selected inclusive source revision
    cursor,
  });
  pages.push(page);
  to = page.to;
  cursor = page.nextCursor ?? undefined;
} while (cursor !== undefined);

// Send the pages through an authenticated, encrypted operator path.
const destination = createPostgresDurabilityStore(vercelPostgresPool);
await importDurabilityStatePages(destination, JSON.parse(JSON.stringify(pages)));

const vercelAgent = await Agent.create({
  module: wasmModule,
  transport,
  durability: destination,
  durabilityId: pages[0].stateId,
});
```

`from` is exclusive and `to` is inclusive. For a nonzero `from`, load the
destination once, hash that exact state with `durabilityStateDigest`, and repeat
the short `fromDigest` on every page request; revision zero's null-state digest
is implied. Each page carries that SHA-256 lineage digest, so import atomically
succeeds only if the destination still has the exact revision and payload
selected at `from`.
Because `to` is one complete Rust state, no intermediate revision log is
needed. Export fences the old source owner, and PostgreSQL reconciles lost
COMMIT responses internally by retrying the identical idempotent request, so
the API never reports an ambiguous write outcome. Stop source admission before
the first page and never resume it after cutover begins. Pages can contain
conversation and tool state, so handle them as secrets. The Vercel example
includes a WASM integration test that executes the
same agent Cloudflare → PostgreSQL → Cloudflare, replays committed turn IDs
without model calls, rebuilds the first new provider request from committed
history without a previous-response handle, and then continues with new turns
on each destination.

The managed Cloudflare service exposes the same offline cutover at `POST
/v1/agents/<agent-id>/durability`; the call permanently closes source admission.
Create a destination with `POST /v1/agents`, an `Idempotency-Key` header, and
`{ "durability": <archive> }`. The stable key owns resumable receipt adoption.
The Vercel example accepts that same body at `POST /api/sessions` and exports a
stopped PostgreSQL state through `POST /api/durability/export` with
`{ "state_id": <durability-id>, "from": <revision>,
"fromDigest": <required-for-nonzero-from>, "to": <optional-revision>,
"cursor": <optional-cursor> }`.

Node embedders whose bundler relocates package assets may compile and pass the
web-target artifact explicitly. The runtime still uses the Node host for
WebSockets and Code Mode:

```js
const module = await WebAssembly.compile(await readFile(wasmAssetPath));
const agent = await Agent.create({ transport: Transport.openAi({ apiKey }), module });
```

A Codex-compatible rollout can also be resumed by materializing its committed
`response_item` history into a snapshot with no `request_prefix`. Nanocodex
rebuilds the current prefix from the supplied instructions and JavaScript tools
while preserving the rollout's workspace, lineage, cache key, canonical user
context, and typed history.

`Agent` and `Actions` are module namespaces, not classes. `Agent.create` returns
an owned client decorated with matching domain actions:

- `agent.turn.prompt(...)` / `Actions.turn.prompt(agent, ...)`
- `turn.accepted()` / `Actions.turn.accepted(turn)`
- `turn.result()` / `Actions.turn.getResult(turn)`
- `result.snapshot()` / `Actions.turn.getSnapshot(result)`
- `result.usage()` / `Actions.turn.getUsage(result)`
- `agent.session.fork(...)` / `Actions.session.fork(agent, ...)`
- `agent.session.compact()` / `Actions.session.compact(agent)`
- `agent.session.snapshot()` / `Actions.session.snapshot(agent)`
- `agent.session.setThinking(...)` / `Actions.session.setThinking(agent, ...)`
- `agent.session.setFastMode(...)` / `Actions.session.setFastMode(agent, ...)`
- `agent.session.shutdown()` / `Actions.session.shutdown(agent)`
- `agent.session.spawn()` / `Actions.session.spawn(agent)`
- `agent.events.watch(...)` / `Actions.events.watch(agent, ...)`

`turn.accepted()` resolves when Rust has admitted the prompt. A durable agent
returns its stable request ID; a custom runtime without durable admission
returns `undefined`. Managed HTTP hosts can await this narrow boundary before
acknowledging a request without waiting for model execution or materializing a
result.

`turn.result()` resolves to a frozen, opaque completed `TurnResult` handle. Its
`finalMessage` is eager. The async `usage()` and `snapshot()` actions materialize
immutable values once and cache their promises. A package Worker completes a
turn with only the message and hidden result identity; Rust-produced snapshot
JSON crosses the Worker boundary only on first demand and is parsed once in the
calling isolate. Historical `fork({ at })` consumes the hidden identity directly,
never an unfinished turn, clone, snapshot, or provider response ID.

The completed result owns its identity independently from the `Turn`, so
`turn.dispose()` does not invalidate a successful result. Call `result.dispose()`
after its last fork/materialization; this releases the retained Worker/native
checkpoint and invalidates future `snapshot()`, `usage()`, and historical forks.
An undisposed result intentionally keeps its package Worker alive after the last
Agent shuts down so its lazy values remain available. Garbage collection is only
a fallback for forgotten handles, not deterministic cleanup.

`turn.dispose()` only releases the JavaScript/WASM handle; like dropping the
Rust `Turn`, it does not cancel accepted work. Await `turn.cancel()` before
disposing unfinished work. At an application or session boundary,
`agent.session.shutdown()` cancels unfinished turns and joins driver, model,
tool, and transport cleanup.

Every action owns its types, for example `Actions.turn.prompt.Options`,
`Actions.turn.prompt.ReturnType`, and `Actions.events.watch.Watcher`.

Event watches are lazy, terminal handles:

```js
const watch = agent.events.watch();
const unlisten = watch.onEvent(console.log);

unlisten();
watch.off();
```

A throwing callback is reported through the host's `reportError` hook (or
`console.error` when that hook is unavailable) without interrupting later
listeners or the owned agent lifecycle.

The same watcher can instead be consumed as an ordered async iterable; breaking
the loop releases that iterator, while `watch.off()` terminates the whole watch.

```js
const watch = agent.events.watch();
for await (const event of watch) {
  console.log(event);
  if (done) break;
}
watch.off();
```

Applications add typed action domains with decorators:

```js
const extended = agent.extend((client) => ({
  inspect: {
    session: () => client.sessionId,
  },
}));

extended.inspect.session();
```

The package-owned browser Worker accepts the same transport policy without
function-valued callbacks:

```js
import { Agent, Transport } from "nanocodex/browser";

const agent = await Agent.create({
  transport: Transport.hostManaged({
    websocketUrl: signedOrCookieAuthorizedEndpoint,
  }),
  threadId,
});
```

Caller-owned browser Workers and server isolates import `nanocodex/host` when
they need function-valued tools or socket construction. Server-side runtimes
can await a `fetch()`-based WebSocket upgrade. The third callback argument is a
discriminated authorization request plus connection metadata, including the
eager `preconnect` request. With `Transport.openAi`, `authorization` is
`"bearer"` and `bearerToken` is present. With `Transport.hostManaged`, it is
`"host_managed"`; the host must resolve credentials without exposing them to
WASM. Do not retain or log bearer tokens. Return the socket alone or a
descriptor containing response metadata:

```js
import { Agent, Transport } from "nanocodex/host";
import module from "nanocodex/wasm";

const agent = await Agent.create({
  transport: Transport.openAi({
    apiKey,
    async createWebSocket(endpoint, sessionId, request) {
      if (request.authorization !== "bearer") {
        throw new Error("this host requires Nanocodex bearer authorization");
      }
      const response = await fetch(endpoint.replace("wss:", "https:"), {
        headers: {
          Authorization: `Bearer ${request.bearerToken}`,
          Upgrade: "websocket",
          "session-id": sessionId,
        },
      });
      if (!response.webSocket) throw new Error(`upgrade failed: ${response.status}`);
      response.webSocket.accept();
      return { socket: response.webSocket, status: response.status };
    },
  }),
  module,
});
```

`Transport.hostManaged` is useful when the embedding runtime owns rotating credentials. The
callback can acquire a fresh token, attempt the upgrade, and refresh-and-retry
on 401. Bound and reject upgrade work in the callback: until it returns a
socket, there is no connection handle for Nanocodex to close. Selecting one
transport makes authentication modes mutually exclusive by construction.

After publication, a browser can load the current-isolate host without a
package manager or build step:

```html
<script type="module">
  import { Agent, Transport } from "https://cdn.jsdelivr.net/npm/nanocodex@0.5.0/host/index.mjs";
  const agent = await Agent.create({
    transport: Transport.hostManaged({
      websocketUrl: "/api/responses",
      createWebSocket: (endpoint) => new WebSocket(endpoint),
    }),
  });
  const turn = agent.turn.prompt({ input: "Hello." });
  let result;
  try {
    result = await turn.result();
    console.log(result.finalMessage);
  } finally {
    try {
      result?.dispose();
    } finally {
      turn.dispose();
      await agent.session.shutdown();
    }
  }
</script>
```

Pin the package version in production. The adjacent WASM file is part of the
npm package and is resolved relative to the host module. This no-build path
runs in the current page isolate; bundled applications should prefer the
package-owned Worker from `nanocodex/browser`. The endpoint must be authorized
by the embedding application because browser WebSockets cannot attach OpenAI's
upgrade authorization header.

The owned Rust session retains follow-on history, response state, tool output,
its WebSocket, and stable prompt-cache identity. Typed browser content accepts
ordered text, remote/data-URL image, and audio items. JavaScript tools are
ordinary async handlers described by JSON Schema and appear in the same ordered
agent event stream as built-in code mode.

Run the standalone Node proof with:

```sh
cd examples/node
npm install
OPENAI_API_KEY=... npm start
```

### Node patch editing

Register `applyPatch` from `nanocodex/node` to use the canonical Rust/WASM
patch planner with a caller-owned workspace:

```js
import { Agent, Transport, Workspace, applyPatch } from "nanocodex/node";

const workspace = await Workspace.open({ path: "./agent-files" });
const agent = await Agent.create({
  transport: Transport.openAi({ apiKey: process.env.OPENAI_API_KEY }),
  tools: { apply_patch: applyPatch({ workspace }) },
});
```

The model can call `apply_patch` directly with a raw patch string or call
`await tools.apply_patch(patch)` inside Code Mode. The tool supports add,
update, move, and delete operations. It does not require setting the agent's
`filesystem` or changing its session workspace. Each tool instance serializes
its patch calls; parsing and hunk verification finish before writes begin.
Filesystem access follows the supplied workspace's rules (the Node workspace
rejects traversal and symlinks). Multi-file writes are not atomic: an I/O
failure reports which operations completed, and external edits are not locked.
