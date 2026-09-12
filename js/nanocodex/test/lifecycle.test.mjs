import assert from "node:assert/strict";
import { setImmediate as immediate } from "node:timers/promises";
import { test } from "node:test";

import { Actions } from "../index.mjs";
import { Agent, Transport } from "../node/index.mjs";
import { createMemoryDurabilityStore } from "../runtime/durability-store.mjs";
import {
  deferred,
  messageReader,
  send,
  sendCompaction,
  sendFinal,
  sendWarmup,
  startResponsesServer,
} from "./support/responses.mjs";

const SESSION_IDS = Object.freeze({
  lifecycle: "018f1f9a-7b3c-7a11-8000-000000000011",
  steer: "018f1f9a-7b3c-7a12-8000-000000000012",
  cancel: "018f1f9a-7b3c-7a13-8000-000000000013",
  compact: "018f1f9a-7b3c-7a14-8000-000000000014",
  fork: "018f1f9a-7b3c-7a15-8000-000000000015",
  reconnect: "018f1f9a-7b3c-7a16-8000-000000000016",
  shutdown: "018f1f9a-7b3c-7a17-8000-000000000017",
  durability: "018f1f9a-7b3c-7a18-8000-000000000018",
  durabilityFence: "018f1f9a-7b3c-7a19-8000-000000000019",
  durabilityCollision: "018f1f9a-7b3c-7a20-8000-000000000020",
});

const createWarmAgent = ({ apiKey, websocketUrl, ...options }) => Agent.create({
  ...options,
  transport: Transport.openAi({ apiKey, websocketUrl, websocketWarmup: true }),
});

test("prompt acceptance is separate from results and healthy follow-ons reuse one socket", async () => {
  const server = await startResponsesServer();
  const firstSeen = deferred();
  const releaseFirst = deferred();
  const events = [];
  let socketClosed;
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.lifecycle,
  });
  const watch = agent.events.watch();
  watch.onEvent((event) => events.push(event));

  const scenario = (async () => {
    const socket = await server.nextConnection();
    socketClosed = new Promise((resolve) => socket.once("close", resolve));
    const reader = messageReader(socket);
    const warmup = await reader.next();
    assert.equal(warmup.generate, false);
    sendWarmup(socket, "resp-warmup");

    const first = await reader.next();
    assert.equal(first.previous_response_id, "resp-warmup");
    assert.match(JSON.stringify(first.input), /first owned prompt/);
    firstSeen.resolve();
    await releaseFirst.promise;
    sendFinal(socket, "resp-first", "FIRST");

    const second = await reader.next();
    assert.equal(second.previous_response_id, "resp-first");
    assert.equal(second.input.length, 1);
    assert.match(JSON.stringify(second.input), /second owned prompt/);
    assert.doesNotMatch(JSON.stringify(second.input), /first owned prompt/);
    sendFinal(socket, "resp-second", "SECOND");
  })();

  const first = agent.turn.prompt({ input: "first owned prompt" });
  assert.equal(typeof first.result, "function");
  assert.equal(await first.accepted(), undefined);
  const firstResult = first.result();
  await firstSeen.promise;
  assert.equal(
    await Promise.race([
      firstResult.then(() => "settled", () => "settled"),
      Promise.resolve("pending"),
    ]),
    "pending",
  );
  releaseFirst.resolve();
  assert.equal((await firstResult).finalMessage, "FIRST");
  assert.equal(
    (await agent.turn.prompt({ input: "second owned prompt" }).result()).finalMessage,
    "SECOND",
  );
  await scenario;
  await immediate();

  assert.equal(server.connections, 1);
  assert.ok(events.length > 2);
  assert.ok(events.every((event, index) => index === 0 || events[index - 1].seq < event.seq));
  assert.equal(events.filter(({ type }) => type === "run.completed").length, 2);

  watch.off();
  agent.dispose();
  await socketClosed;
  await server.close();
});

test("durable acceptance exposes its request ID and classifies conflicts", async () => {
  const server = await startResponsesServer();
  const durabilityId = "lifecycle-acceptance";
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.durability,
    durability: createMemoryDurabilityStore(durabilityId),
    durabilityId,
  });
  const scenario = (async () => {
    const socket = await server.nextConnection();
    const reader = messageReader(socket);
    await reader.next();
    sendWarmup(socket, "resp-durable-warmup");
    const request = await reader.next();
    assert.match(JSON.stringify(request.input), /durable input/);
    sendFinal(socket, "resp-durable", "DURABLE");
  })();

  const turn = agent.turn.prompt({ input: "durable input", id: "operation-7" });
  assert.equal(await turn.accepted(), "operation-7");
  const result = await turn.result();
  assert.equal(result.finalMessage, "DURABLE");
  await scenario;

  const conflict = agent.turn.prompt({ input: "different input", id: "operation-7" });
  await assert.rejects(
    conflict.accepted(),
    (error) => error instanceof Error && error.code === "conflict",
  );
  await assert.rejects(conflict.result(), /already has different input/);

  conflict.dispose();
  result.dispose();
  turn.dispose();
  agent.dispose();
  await server.close();
});

test("a fenced durability owner requires reopening instead of retrying the stale Agent", async () => {
  const durabilityId = "lifecycle-owner-fence";
  const durability = createMemoryDurabilityStore(durabilityId);
  const transport = Transport.openAi({
    apiKey: "test-key",
    websocketUrl: "ws://127.0.0.1:1",
  });
  const first = await Agent.create({
    transport,
    thinking: "low",
    sessionId: SESSION_IDS.durability,
    durability,
    durabilityId,
  });
  const second = await Agent.create({
    transport,
    thinking: "low",
    sessionId: SESSION_IDS.durabilityFence,
    durability,
    durabilityId,
  });

  const turn = first.turn.prompt({ input: "stale owner must stop", id: "operation-fenced" });
  const requiresReopen = (error) => error instanceof Error && error.code === "reopen_required";
  await assert.rejects(turn.accepted(), requiresReopen);
  await assert.rejects(turn.result(), requiresReopen);
  const stopped = first.turn.prompt({ input: "the poisoned driver cannot retry", id: "operation-stopped" });
  await assert.rejects(stopped.accepted(), requiresReopen);
  await assert.rejects(stopped.result(), requiresReopen);

  turn.dispose();
  stopped.dispose();
  first.dispose();
  second.dispose();
});

test("a duplicate durable session rejects without fencing the live Agent", async () => {
  const server = await startResponsesServer();
  const durabilityId = "lifecycle-session-collision";
  const stored = createMemoryDurabilityStore(durabilityId);
  let authorityAcquisitions = 0;
  const durability = {
    acquire(stateId, request) {
      authorityAcquisitions += 1;
      return stored.acquire(stateId, request);
    },
    replace: (stateId, request) => stored.replace(stateId, request),
  };
  const options = {
    transport: Transport.openAi({ apiKey: "test-key", websocketUrl: server.url }),
    thinking: "low",
    sessionId: SESSION_IDS.durabilityCollision,
    durability,
    durabilityId,
  };
  const first = await Agent.create(options);
  const firstAuthorityAcquisitions = authorityAcquisitions;
  assert.ok(firstAuthorityAcquisitions > 0);
  await assert.rejects(Agent.create(options), /session ID is already active/);
  assert.equal(authorityAcquisitions, firstAuthorityAcquisitions);

  const scenario = (async () => {
    const socket = await server.nextConnection();
    const request = await messageReader(socket).next();
    assert.match(JSON.stringify(request.input), /live durable owner/);
    sendFinal(socket, "resp-live-owner", "STILL LIVE");
  })();
  const turn = first.turn.prompt({ input: "live durable owner", id: "operation-live" });
  assert.equal(await turn.accepted(), "operation-live");
  assert.equal((await turn.result()).finalMessage, "STILL LIVE");
  await scenario;

  turn.dispose();
  first.dispose();
  await server.close();
});

test("durability store failures preserve reopen and retry-safe dispositions", async () => {
  const transport = Transport.openAi({
    apiKey: "test-key",
    websocketUrl: "ws://127.0.0.1:1",
  });
  const cases = [
    ["conflict", { status: "conflict", actualRevision: "1" }, "reopen_required"],
    ["backend", new Error("durability backend unavailable"), "reopen_required"],
    [
      "not-committed",
      { status: "not_committed", message: "transaction rolled back" },
      "retryable",
    ],
  ];
  for (const [name, replaceOutcome, expectedCode] of cases) {
    const durabilityId = `lifecycle-store-${name}`;
    const durability = {
      acquire(_stateId, { ownerId }) {
        return { ownerId, fence: "1", revision: "0", payload: null };
      },
      replace() {
        if (replaceOutcome instanceof Error) throw replaceOutcome;
        return replaceOutcome;
      },
    };
    const agent = await Agent.create({
      transport,
      thinking: "low",
      durability,
      durabilityId,
    });
    const turn = agent.turn.prompt({ input: name, id: `operation-${name}` });
    const hasExpectedCode = (error) => error instanceof Error && error.code === expectedCode;
    await assert.rejects(turn.accepted(), hasExpectedCode);
    await assert.rejects(turn.result(), hasExpectedCode);
    turn.dispose();
    agent.dispose();
  }
});

test("steering joins the active turn at the next model boundary", async () => {
  const server = await startResponsesServer();
  const initialSeen = deferred();
  const releaseInitial = deferred();
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.steer,
  });
  const scenario = (async () => {
    const socket = await server.nextConnection();
    const reader = messageReader(socket);
    await reader.next();
    sendWarmup(socket, "resp-steer-warmup");
    const initial = await reader.next();
    assert.match(JSON.stringify(initial.input), /initial task/);
    initialSeen.resolve();
    await releaseInitial.promise;
    sendFinal(socket, "resp-initial", "BOUNDARY");

    const steered = await reader.next();
    assert.equal(steered.previous_response_id, "resp-initial");
    assert.equal(steered.input.length, 1);
    assert.match(JSON.stringify(steered.input), /use the safer path/);
    sendFinal(socket, "resp-steered", "STEERED");
  })();

  const turn = agent.turn.prompt({ input: "initial task" });
  await initialSeen.promise;
  await turn.steer({ input: "use the safer path" });
  releaseInitial.resolve();
  assert.equal((await turn.result()).finalMessage, "STEERED");

  await scenario;
  agent.dispose();
  await server.close();
});

test("cancellation stops the active socket and replays only committed and aborted input", async () => {
  const server = await startResponsesServer();
  const activeSeen = deferred();
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.cancel,
  });
  const scenario = (async () => {
    const socket = await server.nextConnection();
    const reader = messageReader(socket);
    await reader.next();
    sendWarmup(socket, "resp-cancel-warmup");
    const active = await reader.next();
    assert.match(JSON.stringify(active.input), /cancel this work/);
    send(socket, {
      type: "response.output_text.delta",
      delta: "partial output must never commit",
    });
    activeSeen.resolve();
    await new Promise((resolve) => socket.once("close", resolve));

    const replacement = await server.nextConnection();
    const replay = await messageReader(replacement).next();
    assert.equal(replay.previous_response_id, undefined);
    const encoded = JSON.stringify(replay.input);
    assert.match(encoded, /cancel this work/);
    assert.match(encoded, /<turn_aborted>/);
    assert.match(encoded, /continue after cancellation/);
    assert.doesNotMatch(encoded, /partial output must never commit/);
    sendFinal(replacement, "resp-after-cancel", "RECOVERED");
  })();

  const cancelled = agent.turn.prompt({ input: "cancel this work" });
  await activeSeen.promise;
  await cancelled.cancel();
  await assert.rejects(cancelled.result(), /turn was cancelled/);
  assert.equal(
    (await agent.turn.prompt({ input: "continue after cancellation" }).result()).finalMessage,
    "RECOVERED",
  );

  await scenario;
  agent.dispose();
  await server.close();
});

test("graceful shutdown cancels active work and joins transport cleanup exactly once", async () => {
  const server = await startResponsesServer();
  const activeSeen = deferred();
  const socketClosed = deferred();
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.shutdown,
  });
  const scenario = (async () => {
    const socket = await server.nextConnection();
    socket.once("close", socketClosed.resolve);
    const reader = messageReader(socket);
    await reader.next();
    sendWarmup(socket, "resp-shutdown-warmup");
    const active = await reader.next();
    assert.match(JSON.stringify(active.input), /stop this session/);
    activeSeen.resolve();
    await socketClosed.promise;
  })();

  const turn = agent.turn.prompt({ input: "stop this session" });
  await activeSeen.promise;
  const first = agent.session.shutdown();
  const second = Actions.session.shutdown(agent);
  agent.dispose();

  await Promise.all([first, second]);
  await assert.rejects(turn.result(), /turn was cancelled/);
  await scenario;
  assert.throws(
    () => agent.turn.prompt({ input: "too late" }),
    /agent has been disposed/,
  );
  await agent.session.shutdown();
  turn.dispose();

  const replacement = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.shutdown,
  });
  replacement.dispose();
  await server.close();
});

test("a replacement socket drops the remote response ID and replays committed history", async () => {
  const server = await startResponsesServer();
  const firstClosed = deferred();
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.reconnect,
  });
  const scenario = (async () => {
    const original = await server.nextConnection();
    const reader = messageReader(original);
    await reader.next();
    sendWarmup(original, "resp-reconnect-warmup");
    const first = await reader.next();
    assert.equal(first.previous_response_id, "resp-reconnect-warmup");
    sendFinal(original, "resp-before-reconnect", "BEFORE");
    original.once("close", firstClosed.resolve);
    original.terminate();

    const replacement = await server.nextConnection();
    const replay = await messageReader(replacement).next();
    assert.equal(replay.previous_response_id, undefined);
    const encoded = JSON.stringify(replay.input);
    assert.match(encoded, /before replacement/);
    assert.match(encoded, /BEFORE/);
    assert.match(encoded, /after replacement/);
    sendFinal(replacement, "resp-after-reconnect", "AFTER");
  })();

  assert.equal(
    (await agent.turn.prompt({ input: "before replacement" }).result()).finalMessage,
    "BEFORE",
  );
  await firstClosed.promise;
  assert.equal(
    (await agent.turn.prompt({ input: "after replacement" }).result()).finalMessage,
    "AFTER",
  );
  await scenario;
  assert.equal(server.connections, 2);

  agent.dispose();
  await server.close();
});

test("manual compaction and historical forks preserve exact committed boundaries", async () => {
  const server = await startResponsesServer();
  const agent = await createWarmAgent({
    apiKey: "test-key",
    websocketUrl: server.url,
    thinking: "low",
    sessionId: SESSION_IDS.compact,
  });
  const scenario = (async () => {
    const root = await server.nextConnection();
    const reader = messageReader(root);
    await reader.next();
    sendWarmup(root, "resp-history-warmup");

    const first = await reader.next();
    assert.match(JSON.stringify(first.input), /remember copper/);
    sendFinal(root, "resp-first", "stored copper");

    const second = await reader.next();
    assert.equal(second.previous_response_id, "resp-first");
    sendFinal(root, "resp-second", "stored silver");

    const compact = await reader.next();
    assert.equal(compact.previous_response_id, "resp-second");
    assert.deepEqual(compact.input, [{ type: "compaction_trigger" }]);
    sendCompaction(root, "resp-compact");

    const afterCompact = await reader.next();
    assert.equal(afterCompact.previous_response_id, undefined);
    assert.match(JSON.stringify(afterCompact.input), /opaque-js-summary/);
    assert.match(JSON.stringify(afterCompact.input), /after compaction/);
    sendFinal(root, "resp-after-compact", "COMPACTED");

    const branch = await server.nextConnection();
    const branchRequest = await messageReader(branch).next();
    assert.equal(branchRequest.previous_response_id, undefined);
    const encoded = JSON.stringify(branchRequest.input);
    assert.match(encoded, /historical branch/);
    assert.match(encoded, /remember copper/);
    assert.match(encoded, /stored copper/);
    assert.doesNotMatch(encoded, /remember silver/);
    assert.doesNotMatch(encoded, /after compaction/);
    sendFinal(branch, "resp-historical", "BRANCHED");
  })();

  let historical;
  const run = (async () => {
    const first = await agent.turn.prompt({ input: "remember copper" }).result();
    assert.equal(first.finalMessage, "stored copper");
    assert.equal(
      (await agent.turn.prompt({ input: "remember silver" }).result()).finalMessage,
      "stored silver",
    );
    assert.equal(await agent.session.compact(), null);
    assert.equal(
      (await agent.turn.prompt({ input: "after compaction" }).result()).finalMessage,
      "COMPACTED",
    );

    historical = await agent.session.fork({ at: first });
    assert.equal(
      (await historical.turn.prompt({ input: "historical branch" }).result()).finalMessage,
      "BRANCHED",
    );
  })();

  try {
    await Promise.all([scenario, run]);
  } finally {
    historical?.dispose();
    agent.dispose();
    await server.close();
  }
});

test("execution owner cancels a waiting resolver and queued work while retaining the next accepted input", { timeout: 15000 }, async () => {
  const server = await startResponsesServer();
  const started = deferred();
  const storeId = "owner-context-queue";
  const durability = createMemoryDurabilityStore(storeId);
  let current = "old context";
  let cancelledSignal;
  const contexts = [];
  const agent = await Agent.create({
    model: "gpt-5.6-sol",
    thinking: "low",
    transport: Transport.openAi({ apiKey: "test-key", websocketUrl: server.url, websocketWarmup: false }),
    durability,
    durabilityId: storeId,
    resolveContext(context, signal) {
      contexts.push(context.operationId);
      if (context.operationId === "A") {
        cancelledSignal = signal;
        started.resolve();
        return new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
      }
      return { instructions: current };
    },
  });
  const events = [];
  const watcher = agent.events.watch();
  watcher.onEvent(event => { if (event.type === "execution.state") events.push(event); });
  try {
    const a = agent.turn.prompt({ id: "A", input: "waiting A" });
    const aResult = a.result().catch(error => error);
    assert.equal(await a.accepted(), "A");
    await started.promise;
    const b = agent.turn.prompt({ id: "B", input: "retained B" });
    assert.equal(await b.accepted(), "B");
    const c = agent.turn.prompt({ id: "C", input: "cancelled C" });
    const cResult = c.result().catch(error => error);
    assert.equal(await c.accepted(), "C");
    assert.deepEqual((await agent.execution.snapshot()).operations.map(x => [x.operation_id, x.status]),
      [["A", "active"], ["B", "pending"], ["C", "pending"]]);
    await a.steer({ input: "steer the waiting A" });
    await agent.execution.cancel("C");
    assert.equal((await agent.execution.state("C")).status, "cancelled");
    current = "latest host context for B";
    const provider = (async () => {
      const socket = await server.nextConnection();
      const request = await messageReader(socket).next();
      assert.equal(request.input[1].content[0].text, current);
      assert.match(JSON.stringify(request.input), /retained B/);
      assert.doesNotMatch(JSON.stringify(request.input), /cancelled C/);
      sendFinal(socket, "owned-B", "B completed");
    })();
    await agent.execution.cancel("A");
    assert.equal(cancelledSignal.aborted, true);
    assert.ok(await aResult instanceof Error);
    assert.equal((await b.result()).finalMessage, "B completed");
    assert.ok(await cResult instanceof Error);
    await provider;
    assert.deepEqual(contexts, ["A", "B"]);
    assert.deepEqual((await agent.execution.snapshot()).operations.map(x => [x.operation_id, x.status]),
      [["A", "cancelled"], ["B", "completed"], ["C", "cancelled"]]);
    assert.ok(events.some(e => e.payload.operation_id === "B" && e.payload.status === "pending"));
  } finally {
    watcher.off();
    await agent.session.shutdown().catch(() => {});
    agent.dispose();
    await server.close();
  }
});

test("execution recovery loads accepted input by identity after losing handles", { timeout: 15000 }, async () => {
  const server = await startResponsesServer();
  const durabilityId = "owner-resume-by-id";
  const store = createMemoryDurabilityStore(durabilityId);
  const started = deferred();
  const options = {
    model: "gpt-5.6-sol",
    thinking: "low",
    transport: Transport.openAi({ apiKey: "test-key", websocketUrl: server.url, websocketWarmup: false }),
    durabilityId,
  };
  const original = await Agent.create({
    ...options,
    durability: store,
    resolveContext(_context, signal) {
      started.resolve();
      return new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
    },
  });
  let saved;
  try {
    const a = original.turn.prompt({ id: "recover-A", input: "saved original A" });
    a.result().catch(() => {});
    await a.accepted();
    await started.promise;
    const b = original.turn.prompt({ id: "recover-B", input: "saved original B", supplementaryContext: "retained B context" });
    b.result().catch(() => {});
    await b.accepted();
    const c = original.turn.prompt({ id: "recover-C", input: "never dispatch recovered C" });
    c.result().catch(() => {});
    await c.accepted();
    saved = store.snapshot(); // Test-owned crash image, captured before orderly cleanup.
  } finally {
    await original.session.shutdown();
    original.dispose();
  }
  const recovered = await Agent.create({
    ...options,
    durability: createMemoryDurabilityStore(durabilityId, saved),
    resolveContext: () => ({ instructions: "current recovered host persona" }),
  });
  try {
    assert.deepEqual((await recovered.execution.snapshot()).operations.map(x => [x.operation_id, x.status]),
      [["recover-A", "pending"], ["recover-B", "pending"], ["recover-C", "pending"]]);
    await recovered.execution.cancel("recover-C");
    assert.equal((await recovered.execution.state("recover-C")).status, "cancelled");
    const provider = (async () => {
      const socket = await server.nextConnection();
      const reader = messageReader(socket);
      for (const [id, input] of [["A", "saved original A"], ["B", "saved original B"]]) {
        const request = await reader.next();
        assert.match(JSON.stringify(request.input), new RegExp(input));
        if (id === "B") assert.match(JSON.stringify(request.input), /retained B context/);
        if (id === "A") assert.equal(request.input[1].content[0].text, "current recovered host persona");
        sendFinal(socket, `recover-${id}`, `${id} complete`);
      }
    })();
    for (const id of ["A", "B"]) {
      const turn = await recovered.execution.resume(`recover-${id}`);
      assert.equal(await turn.accepted(), `recover-${id}`);
      assert.equal((await turn.result()).finalMessage, `${id} complete`);
    }
    await provider;
    const replay = await recovered.execution.resume("recover-B");
    assert.equal((await replay.result()).finalMessage, "B complete");
    await assert.rejects(recovered.execution.resume("missing"), /unknown|retained/);
    assert.equal(server.connections, 1);
  } finally {
    await recovered.session.shutdown();
    recovered.dispose();
    await server.close();
  }
});


test("queued turns refresh both the provider catalog and dispatch after compaction", { timeout: 15000 }, async () => {
  const server = await startResponsesServer();
  const firstRequest = deferred();
  let currentName = "old_tool";
  let calls = 0;
  let closed = 0;
  const provider = {
    definitions: () => [{ type: "function", name: currentName, description: "Current test tool",
      parameters: { type: "object", properties: {}, additionalProperties: false }, strict: false }],
    resolve: name => name === currentName ? { name, handler: () => { calls++; return "current result"; } } : undefined,
    close: () => { closed++; },
  };
  const agent = await Agent.create({
    model: "gpt-5.6-sol", thinking: "low", subagents: false,
    transport: Transport.openAi({ apiKey: "test-key", websocketUrl: server.url, websocketWarmup: false }),
    toolProviders: [provider],
    resolveContext(context) {
      if (context.input.instruction === "B after compact") currentName = "new_tool";
      return { instructions: `current context ${currentName}` };
    },
  });
  const peer = (async () => {
    const socket = await server.nextConnection();
    const reader = messageReader(socket);
    const a = await reader.next();
    assert.match(JSON.stringify(a.input), /old_tool/);
    firstRequest.resolve();
    sendFinal(socket, "catalog-A", "A complete");
    const compact = await reader.next();
    assert.ok(compact);
    sendCompaction(socket, "catalog-compacted");
    const b = await reader.next();
    assert.match(JSON.stringify(b.input), /new_tool/);
    // Historical text may mention old tools; the current tool contract must not.
    assert.match(JSON.stringify(b.input[0]), /new_tool/);
    assert.doesNotMatch(JSON.stringify(b.input[0]), /old_tool/);
    send(socket, { type: "response.completed", response: { id: "catalog-tools", output: [{
      type: "custom_tool_call", call_id: "catalog-call", name: "exec",
      input: 'text(typeof tools.old_tool); text(await tools.new_tool({}));',
    }] } });
    const result = await reader.next();
    assert.match(JSON.stringify(result.input), /undefined/);
    assert.match(JSON.stringify(result.input), /current result/);
    sendFinal(socket, "catalog-B", "B complete");
  })();
  try {
    const a = agent.turn.prompt({ input: "A before compact" });
    await firstRequest.promise;
    await a.result();
    const compact = agent.session.compact();
    const b = agent.turn.prompt({ input: "B after compact" });
    await compact;
    assert.equal((await b.result()).finalMessage, "B complete");
    await peer;
    assert.equal(calls, 1);
  } finally {
    await agent.session.shutdown().catch(() => {});
    agent.dispose();
    await server.close();
  }
  assert.equal(closed, 1);
});


test("context failure never dispatches stale instructions and the next turn resolves afresh", { timeout: 15000 }, async () => {
  const server = await startResponsesServer();
  let fail = true;
  const agent = await Agent.create({
    model: "gpt-5.6-sol", thinking: "low", instructions: "stale configured context",
    transport: Transport.openAi({ apiKey: "test-key", websocketUrl: server.url, websocketWarmup: false }),
    resolveContext() {
      if (fail) throw new Error("current context unavailable");
      return { instructions: "fresh context" };
    },
  });
  try {
    await assert.rejects(agent.turn.prompt({ input: "fail before dispatch" }).result(), /current context unavailable/);
    assert.equal(server.connections, 0);
    fail = false;
    const peer = (async () => {
      const socket = await server.nextConnection();
      const request = await messageReader(socket).next();
      assert.equal(request.input[1].content[0].text, "fresh context");
      sendFinal(socket, "context-recovered", "done");
    })();
    assert.equal((await agent.turn.prompt({ input: "try current context" }).result()).finalMessage, "done");
    await peer;
  } finally {
    await agent.session.shutdown().catch(() => {});
    agent.dispose();
    await server.close();
  }
});
