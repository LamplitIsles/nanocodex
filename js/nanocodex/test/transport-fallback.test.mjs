import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";

import { Agent, Transport } from "../node/index.mjs";
import { createNodeHost } from "../node/host.mjs";

const SESSION_ID = "018f1f9a-7b3c-7a20-8000-000000000020";

test("Node WASM falls back to HTTP/SSE and keeps the session on SSE", async () => {
  const fixture = await startFallbackFixture(async (request, response, index) => {
    if (index === 0) {
      await sendSse(response, completedResponse("http-tool", [{
        type: "function_call",
        call_id: "lookup-call",
        name: "lookup",
        arguments: JSON.stringify({ key: "cobalt" }),
      }]));
    } else {
      await sendSse(response, completedResponse(
        index === 1 ? "http-first" : "http-follow-on",
        [{
          type: "message",
          role: "assistant",
          content: [{
            type: "output_text",
            text: index === 1 ? "first fallback ✅" : "second SSE ✅",
          }],
        }],
      ));
    }
    void request;
  });
  const toolCalls = [];
  const events = [];
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "fallback-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: SESSION_ID,
    toolMode: "direct",
    tools: {
      lookup: {
        description: "Look up one fixture value.",
        parameters: {
          type: "object",
          properties: { key: { type: "string" } },
          required: ["key"],
          additionalProperties: false,
        },
        handler: ({ key }) => {
          toolCalls.push(key);
          return { value: `found-${key}` };
        },
      },
    },
  });
  const watch = agent.events.watch();
  watch.onEvent((event) => events.push(event));

  try {
    const firstTurn = agent.turn.prompt({ input: "Use lookup for cobalt." });
    const firstResult = await bounded(firstTurn.result(), "first fallback result");
    assert.equal(firstResult.finalMessage, "first fallback ✅");
    firstResult.dispose();
    firstTurn.dispose();

    const secondTurn = agent.turn.prompt({ input: "Continue on the same session." });
    const secondResult = await bounded(secondTurn.result(), "SSE follow-on result");
    assert.equal(secondResult.finalMessage, "second SSE ✅");
    secondResult.dispose();
    secondTurn.dispose();

    const requests = await bounded(fixture.waitForRequests(3), "three HTTP requests");
    assert.equal(fixture.upgrades, 1, "the rejected WebSocket is attempted once");
    assert.deepEqual(toolCalls, ["cobalt"]);
    assert.equal(requests.length, 3);
    for (const request of requests) {
      assert.equal(request.headers.authorization, "Bearer fallback-key");
      assert.equal(request.headers.accept, "text/event-stream");
      assert.equal(request.headers["content-type"], "application/json");
      assert.equal(request.headers["session-id"], SESSION_ID);
      assert.equal(request.headers["thread-id"], SESSION_ID);
      assert.equal(request.headers["x-client-request-id"], SESSION_ID);
    }
    const firstBody = JSON.parse(requests[0].body);
    const continuationBody = JSON.parse(requests[1].body);
    const followOnBody = JSON.parse(requests[2].body);
    assert.match(JSON.stringify(firstBody.input), /Use lookup for cobalt/);
    assert.ok(continuationBody.input.some((item) => item.type === "function_call_output"));
    assert.match(JSON.stringify(followOnBody.input), /Continue on the same session/);
    assert.equal(requests[0].headers["x-codex-turn-state"], undefined);
    assert.equal(requests[1].headers["x-codex-turn-state"], "fixture-turn-state");
    assert.equal(requests[2].headers["x-codex-turn-state"], undefined);

    const fallback = events.find((event) => event.type === "model.attempt.retrying"
      && event.payload.error_class === "websocket_fallback");
    assert.ok(fallback, "the fallback is observable through the public event stream");
    assert.equal(fallback.request_id, SESSION_ID);
    assert.deepEqual(
      {
        previous_transport: fallback.payload.previous_transport,
        next_transport: fallback.payload.next_transport,
        reason: fallback.payload.reason,
      },
      {
        previous_transport: "responses_websocket_v2",
        next_transport: "responses_https_sse",
        reason: "upgrade_required",
      },
    );
    assert.doesNotMatch(JSON.stringify(fallback), /fallback-key|Use lookup for cobalt/);
  } finally {
    watch.off();
    await agent.session.shutdown();
    await fixture.close();
  }
});

test("Node WASM does not fall back for authorization or request rejection", async () => {
  for (const [label, status, body] of [
    ["unauthorized", 401, "API key is missing"],
    ["forbidden", 403, "API key is forbidden"],
    ["request validation", 400, "model is not available"],
  ]) {
    const fixture = await startFallbackFixture(async () => {}, {
      upgrade: { status, body },
    });
    const agent = await Agent.create({
      transport: Transport.openAi({
        apiKey: `${label}-key`,
        websocketUrl: fixture.websocketUrl,
        apiBaseUrl: fixture.apiBaseUrl,
        websocketWarmup: false,
      }),
      model: "gpt-5.6-sol",
      thinking: "none",
      sessionId: `018f1f9a-7b3c-7a20-8000-00000000002${status === 401 ? "5" : status === 403 ? "6" : "7"}`,
    });
    try {
      const turn = agent.turn.prompt({ input: `Reject the ${label} request.` });
      await assert.rejects(bounded(turn.result(), `${label} rejection`));
      await bounded(fixture.waitForUpgradeClose(), `${label} WebSocket close`);
      assert.ok(fixture.upgrades >= 1);
      assert.equal(fixture.requestCount, 0, `${label} must not start HTTP fallback`);
      turn.dispose();
    } finally {
      await agent.session.shutdown().catch(() => {});
      await fixture.close();
    }
  }
});

test("Node host bounds a stalled WebSocket rejection and resets its socket", async () => {
  const fixture = await startFallbackFixture(async () => {}, {
    upgrade: {
      status: 426,
      body: "partial rejection body",
      contentLength: 100,
      stall: true,
    },
  });
  const host = createNodeHost({ connectTimeoutMs: 50 });
  const started = performance.now();
  try {
    await assert.rejects(
      host.connect(fixture.websocketUrl, "stalled-key", SESSION_ID),
      /WebSocket handshake exceeded 50 milliseconds/,
    );
    assert.ok(performance.now() - started < 500, "stalled handshake must honor its deadline");
    await bounded(fixture.waitForUpgradeClose(), "stalled WebSocket close");
    assert.equal(fixture.requestCount, 0);
  } finally {
    await host.dispose();
    await fixture.close();
  }
});

test("Node WASM shutdown closes an initial stalled WebSocket without late fallback", async () => {
  const fixture = await startFallbackFixture(async () => {}, {
    upgrade: {
      status: 426,
      body: "partial rejection body",
      contentLength: 100,
      stall: true,
    },
  });
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "shutdown-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a20-8000-000000000028",
  });
  let turn;
  try {
    turn = agent.turn.prompt({ input: "Shutdown during initial WebSocket setup." });
    const result = turn.result();
    await bounded(fixture.waitForUpgrades(1), "initial WebSocket upgrade");
    await bounded(agent.session.shutdown(), "agent shutdown");
    await assert.rejects(result);
    await bounded(fixture.waitForUpgradeClose(), "shutdown WebSocket close");
    assert.equal(fixture.requestCount, 0, "shutdown must not trigger HTTP fallback");
  } finally {
    turn?.dispose();
    await agent.session.shutdown().catch(() => {});
    await fixture.close();
  }
});

test("Node WASM warmup rejection selects HTTP for the generated request", async () => {
  const fixture = await startFallbackFixture(async (_request, response) => {
    await sendSse(response, completedResponse("warmup-http", [{
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: "warmup recovered" }],
    }]));
  });
  const events = [];
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "warmup-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: true,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a21-8000-000000000021",
  });
  const watch = agent.events.watch();
  watch.onEvent((event) => events.push(event));
  try {
    const turn = agent.turn.prompt({ input: "Recover after warmup rejection." });
    const result = await bounded(turn.result(), "warmup fallback result");
    assert.equal(result.finalMessage, "warmup recovered");
    result.dispose();
    turn.dispose();
    await bounded(fixture.waitForRequests(1), "warmup HTTP request");
    assert.equal(fixture.upgrades, 1);
    assert.ok(events.some((event) => event.type === "model.warmup.failed"));
    assert.ok(events.some((event) => event.type === "model.attempt.retrying"
      && event.payload.error_class === "websocket_fallback"));
  } finally {
    watch.off();
    await agent.session.shutdown();
    await fixture.close();
  }
});

test("Node WASM does not resubmit an SSE request after output starts", async () => {
  const fixture = await startFallbackFixture(async (_request, response) => {
    const event = {
      type: "response.output_text.delta",
      output_index: 0,
      delta: "partial output",
    };
    await writeSse(response, event, { destroy: true });
  });
  const events = [];
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "output-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a22-8000-000000000022",
  });
  const watch = agent.events.watch();
  watch.onEvent((event) => events.push(event));
  try {
    const turn = agent.turn.prompt({ input: "Do not repeat this request." });
    await assert.rejects(bounded(turn.result(), "post-output failure"));
    assert.ok(events.some((event) => event.type === "assistant.delta"
      && event.payload.text === "partial output"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(fixture.upgrades, 1);
    assert.equal(fixture.requestCount, 1, "output failure is terminal for this request");
    turn.dispose();
  } finally {
    watch.off();
    await agent.session.shutdown();
    await fixture.close();
  }
});

test("cancelling an HTTP body closes the host-owned request", async () => {
  let bodyClosed;
  let bodySent;
  const closed = new Promise((resolve) => { bodyClosed = resolve; });
  const bodyReady = new Promise((resolve) => { bodySent = resolve; });
  const fixture = await startFallbackFixture(async (_request, response) => {
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      "x-codex-turn-state": "cancelled-state",
    });
    response.flushHeaders();
    response.write(": body flushed\n\n", bodySent);
    response.once("close", () => bodyClosed());
  });
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "cancel-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a23-8000-000000000023",
  });
  try {
    const turn = agent.turn.prompt({ input: "Cancel while reading SSE." });
    const result = turn.result();
    await bounded(fixture.waitForRequests(1), "cancelled HTTP request");
    await bounded(bodyReady, "flushed HTTP body");
    await bounded(turn.cancel(), "turn cancellation");
    await assert.rejects(result);
    await bounded(closed, "HTTP body close");
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(fixture.upgrades, 1);
    assert.equal(fixture.requestCount, 1);
    turn.dispose();
  } finally {
    await agent.session.shutdown();
    await fixture.close();
  }
});

test("cancelling an HTTP connect closes a request waiting for headers", async () => {
  let closed;
  const requestClosed = new Promise((resolve) => { closed = resolve; });
  const fixture = await startFallbackFixture(async (_request, response) => {
    response.once("close", () => closed());
    await requestClosed;
  });
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "connect-cancel-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a23-8000-000000000024",
  });
  try {
    const turn = agent.turn.prompt({ input: "Cancel while waiting for HTTP headers." });
    const result = turn.result();
    await bounded(fixture.waitForRequests(1), "HTTP connect request");
    await bounded(turn.cancel(), "connect cancellation");
    await assert.rejects(result);
    await bounded(requestClosed, "HTTP connect close");
    assert.equal(fixture.upgrades, 1);
    assert.equal(fixture.requestCount, 1);
    turn.dispose();
  } finally {
    await agent.session.shutdown();
    await fixture.close();
  }
});

test("HTTP fallback preserves a history seed through manual compaction", async () => {
  const fixture = await startFallbackFixture(async (_request, response, index) => {
    if (index === 0) {
      await sendSse(response, completedResponse("seeded-first", [{
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "seed continuation" }],
      }]));
      return;
    }
    if (index === 1) {
      await sendSse(response, completedResponse("seeded-summary", [{
        type: "compaction",
        encrypted_content: "PRIVATE_SSE_SUMMARY",
      }]));
      return;
    }
    await sendSse(response, completedResponse("seeded-follow-on", [{
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: "after SSE compaction" }],
    }]));
  });
  const events = [];
  const agent = await Agent.create({
    transport: Transport.openAi({
      apiKey: "seeded-key",
      websocketUrl: fixture.websocketUrl,
      apiBaseUrl: fixture.apiBaseUrl,
      websocketWarmup: false,
    }),
    model: "gpt-5.6-sol",
    thinking: "none",
    sessionId: "018f1f9a-7b3c-7a20-8000-000000000029",
    historySeed: {
      history: [
        {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: "remember the violet room" }],
        },
        {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "I will remember it." }],
          status: "completed",
        },
      ],
      continuitySummary: "The user is discussing the violet room.",
    },
  });
  const watch = agent.events.watch();
  watch.onEvent((event) => events.push(event));
  try {
    const firstTurn = agent.turn.prompt({ input: "Continue the seeded conversation." });
    const firstResult = await bounded(firstTurn.result(), "seeded fallback result");
    assert.equal(firstResult.finalMessage, "seed continuation");
    firstResult.dispose();
    firstTurn.dispose();

    await bounded(agent.session.compact(), "SSE manual compaction");
    const followOn = agent.turn.prompt({ input: "Continue after SSE compaction." });
    const followOnResult = await bounded(followOn.result(), "SSE compacted follow-on");
    assert.equal(followOnResult.finalMessage, "after SSE compaction");
    followOnResult.dispose();
    followOn.dispose();

    const requests = await bounded(fixture.waitForRequests(3), "seeded SSE requests");
    assert.equal(fixture.upgrades, 1);
    assert.equal(requests.length, 3);
    assert.match(requests[0].body, /violet room/);
    assert.match(requests[0].body, /Continue the seeded conversation/);
    assert.match(requests[1].body, /compaction_trigger/);
    assert.match(requests[2].body, /PRIVATE_SSE_SUMMARY/);
    assert.match(requests[2].body, /Continue after SSE compaction/);
    assert.ok(events.some((event) => event.type === "model.compaction.completed"));
    assert.equal(
      events.filter((event) =>
        (event.type === "assistant.delta" || event.type === "assistant.message")
        && event.payload.text.includes("PRIVATE_SSE_SUMMARY")).length,
      0,
    );
  } finally {
    watch.off();
    await agent.session.shutdown();
    await fixture.close();
  }
});

async function startFallbackFixture(onRequest, options = {}) {
  let upgrades = 0;
  const upgrade = options.upgrade ?? {};
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== "/v1/responses") {
      response.writeHead(404);
      response.end();
      return;
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const entry = {
      headers: request.headers,
      body: Buffer.concat(chunks).toString("utf8"),
    };
    state.requests.push(entry);
    for (const waiter of [...state.waiters]) {
      if (state.requests.length >= waiter.count) {
        state.waiters.splice(state.waiters.indexOf(waiter), 1);
        waiter.resolve(state.requests.slice(0, waiter.count));
      }
    }
    await onRequest(entry, response, state.requests.length - 1);
  });
  const sockets = new Set();
  const upgradeSockets = new Set();
  const upgradeCountWaiters = [];
  const upgradeCloseWaiters = [];
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.once("close", () => sockets.delete(socket));
  });
  const state = {
    requests: [],
    waiters: [],
    get upgrades() { return upgrades; },
    get requestCount() { return this.requests.length; },
    get websocketUrl() { return `ws://127.0.0.1:${server.address().port}/v1/responses`; },
    get apiBaseUrl() { return `http://127.0.0.1:${server.address().port}/v1`; },
    waitForRequests(count) {
      if (this.requests.length >= count) return Promise.resolve(this.requests.slice(0, count));
      return new Promise((resolve) => this.waiters.push({ count, resolve }));
    },
    waitForUpgrades(count) {
      if (upgrades >= count) return Promise.resolve(upgrades);
      return new Promise((resolve) => upgradeCountWaiters.push({ count, resolve }));
    },
    waitForUpgradeClose() {
      if (upgradeSockets.size === 0) return Promise.resolve();
      return new Promise((resolve) => upgradeCloseWaiters.push(resolve));
    },
    close() {
      for (const socket of sockets) socket.destroy();
      return new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
    },
  };
  server.on("upgrade", (_request, socket) => {
    upgrades += 1;
    for (const waiter of [...upgradeCountWaiters]) {
      if (upgrades >= waiter.count) {
        upgradeCountWaiters.splice(upgradeCountWaiters.indexOf(waiter), 1);
        waiter.resolve(upgrades);
      }
    }
    upgradeSockets.add(socket);
    socket.once("close", () => {
      upgradeSockets.delete(socket);
      if (upgradeSockets.size === 0) {
        for (const waiter of upgradeCloseWaiters.splice(0)) waiter();
      }
    });
    const status = upgrade.status ?? 426;
    const body = Buffer.from(upgrade.body ?? "WebSocket transport disabled in fixture");
    const reason = upgradeReason(status);
    const contentLength = upgrade.contentLength ?? body.byteLength;
    socket.write(
      `HTTP/1.1 ${status} ${reason}\r\n`
      + `Content-Type: text/plain\r\n`
      + `Content-Length: ${contentLength}\r\n`
      + `Connection: ${upgrade.stall ? "keep-alive" : "close"}\r\n\r\n`,
    );
    if (upgrade.stall) socket.write(body);
    else socket.end(body);
  });
  await new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", resolve);
    server.once("error", reject);
  });
  return Object.freeze(state);
}

function upgradeReason(status) {
  return {
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    426: "Upgrade Required",
  }[status] ?? "Rejected";
}

function completedResponse(id, output) {
  return {
    type: "response.completed",
    response: { id, status: "completed", output, usage: null },
  };
}

async function sendSse(response, event) {
  return writeSse(response, event);
}

async function writeSse(response, event, options = {}) {
  return writeSseEvents(response, [event], options);
}

async function writeSseEvents(response, events, options = {}) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    "x-request-id": "fixture-request",
    "x-codex-turn-state": "fixture-turn-state",
  });
  for (const event of events) {
    const bytes = Buffer.from(`data: ${JSON.stringify(event)}\n\n`);
    for (let offset = 0; offset < bytes.length; offset += 5) {
      response.write(bytes.subarray(offset, offset + 5));
      await new Promise((resolve) => setImmediate(resolve));
    }
  }
  if (options.destroy) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    response.destroy();
  } else {
    response.end("data: [DONE]\n\n");
  }
}

async function bounded(promise, stage) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`timed out waiting for ${stage}`)), 5_000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
