import assert from "node:assert/strict";
import { test } from "node:test";
import { createNodeHost } from "../node/host.mjs";

function pendingRequest(t) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let resolveResponse;
  let signal;
  t.mock.method(globalThis, "fetch", (_url, options) => {
    signal = options.signal;
    return new Promise((resolve, reject) => {
      resolveResponse = resolve;
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
  });
  const host = createNodeHost({ toolMode: "direct", connectTimeoutMs: 10 });
  t.after(() => host.dispose());
  return { host, signal: () => signal, respond: (response) => resolveResponse(response) };
}

async function open(host) {
  const { handle } = JSON.parse(await host.httpOpen("https://example.invalid/responses", "fake", "test", "{}"));
  return { handle, headers: host.httpHeaders(handle) };
}

test("HTTP headers have a separate 60-second deadline", async (t) => {
  const request = pendingRequest(t);
  const { headers } = await open(request.host);
  const failure = headers.catch((error) => error);
  t.mock.timers.tick(59_999);
  assert.equal(request.signal().aborted, false);
  t.mock.timers.tick(1);
  const error = await failure;
  assert.equal(error.timeout, true);
  assert.equal(error.reconnectable, true);
  assert.match(error.message, /headers exceeded 60000 milliseconds/);
});

test("closing pending HTTP headers cancels without a retryable timeout", async (t) => {
  const request = pendingRequest(t);
  const { handle, headers } = await open(request.host);
  const failure = headers.catch((error) => error);
  request.host.close(handle);
  const error = await failure;
  assert.equal(request.signal().aborted, true);
  assert.equal(error.timeout, false);
  assert.equal(error.reconnectable, false);
  assert.doesNotMatch(error.message, /\n\s+at /);
  t.mock.timers.tick(60_000);
  assert.equal(error.timeout, false);
});

test("received headers retire their deadline while body reads keep their own timeout", async (t) => {
  const request = pendingRequest(t);
  const { handle, headers } = await open(request.host);
  let cancelled = false;
  request.respond(new Response(new ReadableStream({ cancel() { cancelled = true; } })));
  await headers;
  t.mock.timers.tick(60_000);
  assert.equal(request.signal().aborted, false);
  const next = request.host.next(handle, 25);
  t.mock.timers.tick(25);
  assert.equal(JSON.parse(await next).kind, "timeout");
  assert.equal(cancelled, true);
});

test("HTTP bridge preserves timeout and cancellation classification without display stacks", async () => {
  const { installHostBridge, bindHostSession, releaseHostSession } = await import("../internal.mjs");
  const previous = globalThis.nanocodexHost;
  installHostBridge();
  const session = "http-classification-test";
  let failure;
  const host = {
    httpOpen: async () => JSON.stringify({ handle: 1 }),
    httpHeaders: async () => { throw failure; },
  };
  bindHostSession(host, session);
  try {
    for (const timeout of [true, false]) {
      failure = Object.assign(new Error(timeout ? "headers exceeded 60000 milliseconds" : "request aborted"), {
        timeout, reconnectable: timeout,
      });
      const { handle } = JSON.parse(await globalThis.nanocodexHost.httpOpen(
        "https://example.invalid/responses", "fake", null, false, session, session, null, "{}",
      ));
      await assert.rejects(globalThis.nanocodexHost.httpHeaders(handle), (encoded) => {
        assert.deepEqual(JSON.parse(encoded), {
          kind: "transport", detail: failure.message, timeout, reconnectable: timeout,
        });
        return true;
      });
    }
  } finally {
    releaseHostSession(host, session);
    if (previous === undefined) delete globalThis.nanocodexHost;
    else globalThis.nanocodexHost = previous;
  }
});
