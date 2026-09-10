import { Console } from "node:console";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import WebSocket from "ws";
import packageMetadata from "../package.json" with { type: "json" };

import { createCodeRuntime } from "../runtime/code-runtime.mjs";
import { createMcpRuntime } from "../runtime/mcp-runtime.mjs";
import {
  settleCleanup,
  toolRouterBrand,
  toolRouterRuntime,
  toolRuntimeLifecycle,
} from "../runtime/tool-router.mjs";
import { utf8ByteLength } from "../runtime/utf8.mjs";

const RESPONSES_WEBSOCKETS_BETA = "responses_websockets=2026-02-06";
const USER_AGENT = `nanocodex-wasm/${packageMetadata.version}`;
const DEFAULT_MAX_QUEUED_MESSAGES = 4_096;
const DEFAULT_MAX_QUEUED_BYTES = 32 * 1024 * 1024;
const DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024;
const DEFAULT_CONNECT_TIMEOUT_MS = 15_000;
const MAX_HTTP_ERROR_BYTES = 64 * 1024;
const MPP_CLIENT_PROTOCOL_ERROR_CLOSE_CODE = 3008;

export function createNodeHost(options = {}) {
  const toolMode = options.toolMode ?? "code";
  if (toolMode !== "code" && toolMode !== "direct") {
    throw new TypeError("toolMode must be code or direct");
  }
  const toolsRouter = options.tools?.[toolRouterBrand]
    ? options.tools[toolRouterRuntime]
    : undefined;
  const toolsMcp = toolsRouter?.hasSourceKind("mcp") === true;
  if (toolsRouter?.hasSource("workspace") && options.filesystem) {
    throw new TypeError("workspace is already configured in Tools");
  }
  if (toolsMcp && options.mcpServers) {
    throw new TypeError("MCP is already configured in Tools");
  }
  if ((toolsMcp || options.mcpServers) && toolMode !== "code") {
    throw new TypeError("remote MCP requires Code Mode");
  }
  const toolsLifecycle = options.tools?.[toolRuntimeLifecycle];
  toolsLifecycle?.available();
  const connections = new Map();
  const code = createCodeRuntime(options.tools, {
    require: createRequire(resolve(options.workspace ?? process.cwd(), ".nanocodex-code-mode.cjs")),
    console: new Console({ stdout: process.stderr, stderr: process.stderr }),
    evaluate: options.codeEvaluator,
  });
  const filesystem = options.filesystem
    ? import("../runtime/workspace.mjs")
        .then(({ tools }) => code.addTools(tools(options.filesystem)))
    : undefined;
  const mcp = options.mcpServers
    ? createMcpRuntime(options.mcpServers, { clientName: "nanocodex-node" })
    : undefined;
  let disposal;
  const mcpInstalled = mcp?.then(async (provider) => {
    if (disposal) {
      await provider.close();
      return;
    }
    try { code.addProvider(provider, { id: "mcp", kind: "mcp" }); }
    catch (error) {
      try { await provider.close(); }
      catch (cleanupError) {
        throw new AggregateError([error, cleanupError], "MCP installation and cleanup failed");
      }
      throw error;
    }
  });
  const onEvent = options.onEvent || (() => {});
  const connectTimeoutMs = Math.min(
    options.connectTimeoutMs ?? DEFAULT_CONNECT_TIMEOUT_MS,
    DEFAULT_CONNECT_TIMEOUT_MS,
  );
  const sendTimeoutMs = options.sendTimeoutMs ?? 30_000;
  const maxQueuedMessages = options.maxQueuedMessages ?? DEFAULT_MAX_QUEUED_MESSAGES;
  const maxQueuedBytes = options.maxQueuedBytes ?? DEFAULT_MAX_QUEUED_BYTES;
  const maxFrameBytes = options.maxFrameBytes ?? DEFAULT_MAX_FRAME_BYTES;
  let nextHandle = 1;
  let references = 0;
  const httpConnections = new Map();

  function connect(endpoint, apiKey, sessionId, metadata = {}) {
    if (options.mpp) return connectMpp(endpoint);
    return new Promise((resolve, reject) => {
      let settled = false;
      let upgradeResponse;
      let upgradeRequest;
      let deadline;
      let rejectionResponse;
      const threadId = metadata.threadId ?? sessionId;
      const headers = {
        Authorization: `Bearer ${apiKey}`,
        "OpenAI-Beta": RESPONSES_WEBSOCKETS_BETA,
        "x-openai-internal-codex-responses-lite": "true",
        "session-id": sessionId,
        "thread-id": threadId,
        "x-client-request-id": threadId,
        "x-responsesapi-include-timing-metrics": "true",
        "User-Agent": USER_AGENT,
      };
      if (metadata.accountId) headers["ChatGPT-Account-ID"] = metadata.accountId;
      if (metadata.fedramp) headers["X-OpenAI-Fedramp"] = "true";
      if (metadata.turnState) headers["x-codex-turn-state"] = metadata.turnState;
      const socket = new WebSocket(endpoint, {
        maxPayload: maxFrameBytes,
        headers,
      });
      const handle = nextHandle++;
      const connection = queueState(socket);
      connection.connecting = true;
      connections.set(handle, connection);

      const fail = (error, reset = false) => {
        if (settled) return;
        settled = true;
        clearTimeout(deadline);
        connections.delete(handle);
        connection.intentionallyClosed = true;
        destroyWebSocket(socket, upgradeRequest, rejectionResponse, reset);
        reject(error);
      };
      const rejectAsClosed = () => {
        const error = new Error("WebSocket connection was closed by the host");
        error.reconnectable = false;
        fail(error, true);
      };

      socket.on("upgrade", (response) => { upgradeResponse = response; });
      socket.on("unexpected-response", (request, response) => {
        if (settled) return;
        upgradeRequest = request;
        rejectionResponse = response;
        readHandshakeRejection(response, (error) => fail(error));
      });
      socket.on("open", () => {
        if (settled) {
          destroyWebSocket(socket);
          return;
        }
        settled = true;
        clearTimeout(deadline);
        connection.connecting = false;
        const headers = upgradeResponse?.headers || {};
        resolve(JSON.stringify({
          handle,
          status: upgradeResponse?.statusCode || 101,
          request_id: header(headers, "x-request-id"),
          server_model: header(headers, "openai-model"),
          reasoning_included: header(headers, "x-reasoning-included") !== undefined,
          turn_state: header(headers, "x-codex-turn-state"),
        }));
      });
      socket.on("message", (data, isBinary) => {
        enqueue(connection, isBinary
          ? { kind: "binary" }
          : { kind: "text", text: data.toString("utf8") });
      });
      socket.on("close", (status, reason) => {
        if (!settled) {
          const suffix = reason.length ? `: ${reason.toString("utf8")}` : "";
          fail(new Error(`WebSocket connection closed during handshake with code ${status}${suffix}`));
        } else if (!connection.intentionallyClosed && !connection.overflowed) {
          const suffix = reason.length ? `: ${reason.toString("utf8")}` : "";
          enqueue(connection, { kind: "closed", detail: `with code ${status}${suffix}` });
        }
      });
      socket.on("error", (error) => {
        if (!settled) {
          fail(error, true);
        } else {
          enqueue(connection, { kind: "error", detail: errorMessage(error) });
        }
      });
      deadline = setTimeout(() => {
        const error = new Error(
          `WebSocket handshake exceeded ${connectTimeoutMs} milliseconds`,
        );
        error.reconnectable = true;
        fail(error, true);
      }, connectTimeoutMs);
      connection.reject = rejectAsClosed;
    });
  }

  async function connectMpp(endpoint) {
    if (typeof options.mpp.ws !== "function") {
      throw new TypeError("mpp must provide ws(endpoint)");
    }
    const socket = await options.mpp.ws(endpoint);
    if (!socket || typeof socket.addEventListener !== "function") {
      throw new TypeError("mpp.ws(endpoint) must return a WebSocket");
    }
    const handle = nextHandle++;
    const connection = queueState(socket);
    connection.managed = true;
    connections.set(handle, connection);
    socket.addEventListener("message", (event) => {
      enqueue(connection, typeof event.data === "string"
        ? { kind: "text", text: event.data }
        : { kind: "binary" });
    });
    socket.addEventListener("close", (event) => {
      if (!connection.intentionallyClosed && !connection.overflowed) {
        const code = event.code ?? 1000;
        const suffix = event.reason ? `: ${event.reason}` : "";
        enqueue(connection, code === MPP_CLIENT_PROTOCOL_ERROR_CLOSE_CODE
          ? {
              kind: "error",
              detail: `MPP WebSocket payment flow failed with code ${code}${suffix}`,
              reconnectable: false,
            }
          : { kind: "closed", detail: `with code ${code}${suffix}` });
      }
    });
    socket.addEventListener("error", () => {
      enqueue(connection, { kind: "error", detail: "MPP WebSocket connection failed" });
    });
    return JSON.stringify({ handle, status: 101, reasoning_included: false });
  }

  async function httpOpen(endpoint, apiKey, sessionId, body, metadata = {}) {
    if (options.mpp) {
      throw new Error("MPP transport does not support HTTPS Responses fallback");
    }
    if (typeof fetch !== "function") {
      throw new Error("the Node host requires a global fetch implementation for HTTPS Responses");
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), connectTimeoutMs);
    const threadId = metadata.threadId ?? sessionId;
    const headers = {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      Accept: "text/event-stream",
      "x-openai-internal-codex-responses-lite": "true",
      "session-id": sessionId,
      "thread-id": threadId,
      "x-client-request-id": threadId,
      "User-Agent": USER_AGENT,
    };
    if (metadata.accountId) headers["ChatGPT-Account-ID"] = metadata.accountId;
    if (metadata.fedramp) headers["X-OpenAI-Fedramp"] = "true";
    if (metadata.turnState) headers["x-codex-turn-state"] = metadata.turnState;
    let responsePromise;
    try {
      responsePromise = fetch(endpoint, {
        method: "POST",
        headers,
        body,
        signal: controller.signal,
      });
    } catch (error) {
      controller.abort();
      clearTimeout(timer);
      throw error;
    }
    const handle = nextHandle++;
    const connection = {
      response: undefined,
      responsePromise: undefined,
      controller,
      reader: undefined,
      decoder: new TextDecoder("utf-8", { fatal: true }),
      reading: false,
      closed: false,
    };
    connection.responsePromise = Promise.resolve(responsePromise).then((response) => {
      clearTimeout(timer);
      if (connection.closed) {
        void response.body?.cancel().catch(() => {});
      } else {
        connection.response = response;
      }
      return response;
    }, (error) => {
      clearTimeout(timer);
      const timedOut = error?.name === "AbortError";
      const failure = new Error(timedOut
        ? `HTTPS Responses request headers exceeded ${connectTimeoutMs} milliseconds`
        : errorMessage(error));
      failure.reconnectable = true;
      failure.timeout = timedOut;
      throw failure;
    });
    // A caller may close the handle before awaiting headers. Keep the
    // rejection observed while preserving it for the header caller.
    connection.responsePromise.catch(() => {});
    httpConnections.set(handle, connection);
    return JSON.stringify({ handle });
  }

  async function httpHeaders(handle) {
    const connection = httpConnections.get(handle);
    if (!connection || connection.closed) {
      throw new Error("unknown HTTPS handle");
    }
    let response;
    try {
      response = await connection.responsePromise;
    } catch (error) {
      closeHttp(connection, handle);
      throw error;
    }
    if (connection.closed) throw new Error("HTTPS Responses handle was closed");
    if (!response.ok) {
      try {
        const body = await readHttpErrorBody(connection);
        const error = new Error(
          `HTTPS Responses request was rejected with HTTP ${response.status}`,
        );
        error.status = response.status;
        error.body = body;
        const retryAfter = Number(response.headers.get("retry-after"));
        if (Number.isFinite(retryAfter) && retryAfter >= 0) error.retryAfter = retryAfter;
        throw error;
      } finally {
        closeHttp(connection, handle);
      }
    }
    return JSON.stringify({
      status: response.status,
      request_id: response.headers.get("x-request-id") ?? undefined,
      server_model: response.headers.get("openai-model") ?? undefined,
      reasoning_included: response.headers.has("x-reasoning-included"),
      turn_state: response.headers.get("x-codex-turn-state") ?? undefined,
    });
  }

  function send(handle, message) {
    if (httpConnections.has(handle)) {
      return Promise.resolve(JSON.stringify({
        ok: false,
        reconnectable: false,
        error: "HTTPS Responses connections do not accept WebSocket frames",
      }));
    }
    const connection = connections.get(handle);
    if (!connection || connection.socket.readyState !== WebSocket.OPEN) {
      return Promise.resolve(JSON.stringify({
        ok: false,
        reconnectable: true,
        error: "WebSocket is no longer open",
      }));
    }
    if (connection.managed) {
      try {
        connection.socket.send(JSON.stringify({ mpp: "message", data: message }));
        return Promise.resolve(JSON.stringify({ ok: true }));
      } catch (error) {
        return Promise.resolve(JSON.stringify({
          ok: false,
          reconnectable: connection.socket.readyState !== WebSocket.OPEN,
          error: errorMessage(error),
        }));
      }
    }
    return new Promise((resolve) => {
      let completed = false;
      const timer = setTimeout(() => finish({
        ok: false,
        reconnectable: false,
        error: `sending a WebSocket frame exceeded ${sendTimeoutMs} milliseconds`,
      }), sendTimeoutMs);
      function finish(result) {
        if (completed) return;
        completed = true;
        clearTimeout(timer);
        resolve(JSON.stringify(result));
      }
      connection.socket.send(message, (error) => finish(error ? {
        ok: false,
        reconnectable: connection.socket.readyState !== WebSocket.OPEN,
        error: errorMessage(error),
      } : { ok: true }));
    });
  }

  function next(handle, timeoutMs) {
    if (httpConnections.has(handle)) return nextHttp(handle, timeoutMs);
    const connection = connections.get(handle);
    if (!connection) {
      return Promise.resolve(JSON.stringify({ kind: "closed", detail: "before the next frame" }));
    }
    if (connection.queue.length) {
      const entry = connection.queue.shift();
      connection.queuedBytes -= entry.bytes;
      return Promise.resolve(JSON.stringify(entry.message));
    }
    if (connection.waiter) return Promise.reject(new Error("concurrent reads are unsupported"));
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        connection.waiter = undefined;
        resolve(JSON.stringify({ kind: "timeout" }));
      }, timeoutMs);
      connection.waiter = (message) => {
        clearTimeout(timer);
        connection.waiter = undefined;
        resolve(JSON.stringify(message));
      };
    });
  }

  function close(handle) {
    const httpConnection = httpConnections.get(handle);
    if (httpConnection) {
      httpConnections.delete(handle);
      closeHttp(httpConnection, handle);
      return;
    }
    const connection = connections.get(handle);
    if (!connection) return;
    if (connection.connecting) {
      connection.reject?.();
      return;
    }
    connections.delete(handle);
    connection.intentionallyClosed = true;
    connection.waiter?.({ kind: "closed", detail: "by the WASM runtime" });
    connection.socket.close();
  }

  async function nextHttp(handle, timeoutMs) {
    const connection = httpConnections.get(handle);
    if (!connection || connection.closed) {
      return JSON.stringify({ kind: "closed", detail: "before the next HTTPS chunk" });
    }
    if (connection.reading) {
      throw new Error("concurrent HTTPS reads are unsupported");
    }
    connection.reading = true;
    try {
      if (!connection.response) {
        closeHttp(connection, handle);
        return JSON.stringify({ kind: "error", detail: "HTTPS headers were not consumed" });
      }
      if (!connection.reader) {
        if (!connection.response.body) {
          httpConnections.delete(handle);
          closeHttp(connection, handle, false);
          return JSON.stringify({ kind: "eof" });
        }
        connection.reader = connection.response.body.getReader();
      }
      const read = connection.reader.read();
      let timeout;
      let result;
      try {
        result = await Promise.race([
          read,
          new Promise((resolve) => {
            timeout = setTimeout(() => resolve({ timedOut: true }), timeoutMs);
          }),
        ]);
      } finally {
        clearTimeout(timeout);
      }
      if (result.timedOut) {
        read.catch(() => {});
        closeHttp(connection, handle);
        return JSON.stringify({ kind: "timeout" });
      }
      if (result.done) {
        let tail;
        try {
          tail = connection.decoder.decode();
        } catch (error) {
          closeHttp(connection, handle);
          return JSON.stringify({
            kind: "error",
            detail: `invalid HTTPS response UTF-8: ${errorMessage(error)}`,
          });
        }
        if (tail) {
          return JSON.stringify({ kind: "chunk", text: tail });
        }
        httpConnections.delete(handle);
        closeHttp(connection, handle, false);
        return JSON.stringify({ kind: "eof" });
      }
      let text;
      try {
        text = connection.decoder.decode(result.value, { stream: true });
      } catch (error) {
        closeHttp(connection, handle);
        return JSON.stringify({
          kind: "error",
          detail: `invalid HTTPS response UTF-8: ${errorMessage(error)}`,
        });
      }
      return JSON.stringify({ kind: "chunk", text });
    } catch (error) {
      closeHttp(connection, handle);
      throw error;
    } finally {
      connection.reading = false;
    }
  }

  async function readHttpErrorBody(connection) {
    if (!connection.response.body) return "";
    const reader = connection.reader || connection.response.body.getReader();
    connection.reader = reader;
    const decoder = new TextDecoder();
    const parts = [];
    let length = 0;
    let truncated = false;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const remaining = MAX_HTTP_ERROR_BYTES - length;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        const chunk = value.subarray(0, remaining);
        parts.push(decoder.decode(chunk, { stream: true }));
        length += chunk.byteLength;
        if (chunk.byteLength < value.byteLength) {
          truncated = true;
          break;
        }
      }
      parts.push(decoder.decode());
    } finally {
      if (truncated) void reader.cancel().catch(() => {});
    }
    return parts.join("") + (truncated ? "…" : "");
  }

  function closeHttp(connection, handle, abort = true) {
    if (connection.closed) return;
    connection.closed = true;
    if (abort) connection.controller.abort();
    if (connection.reader) void connection.reader.cancel().catch(() => {});
    if (!connection.response && connection.responsePromise) {
      connection.responsePromise.then((response) => response.body?.cancel()).catch(() => {});
    }
    if (httpConnections.get(handle) === connection) httpConnections.delete(handle);
  }

  function enqueue(connection, message) {
    if (connection.overflowed) return;
    if (connection.waiter) {
      connection.waiter(message);
      return;
    }
    const bytes = messageBytes(message);
    if (connection.queue.length >= maxQueuedMessages || connection.queuedBytes + bytes > maxQueuedBytes) {
      connection.queue.length = 0;
      connection.queuedBytes = 0;
      connection.overflowed = true;
      const error = {
        kind: "error",
        detail: `receive queue exceeded ${maxQueuedMessages} messages or ${maxQueuedBytes} bytes`,
      };
      connection.queue.push({ message: error, bytes: messageBytes(error) });
      if (typeof connection.socket.terminate === "function") connection.socket.terminate();
      else connection.socket.close(1009, "receive queue exceeded configured bounds");
      return;
    }
    connection.queue.push({ message, bytes });
    connection.queuedBytes += bytes;
  }

  function dispose() {
    if (disposal) return disposal;
    disposal = Promise.resolve().then(() => settleCleanup([
      ...[...connections.keys()].map((handle) => () => close(handle)),
      ...[...httpConnections.keys()].map((handle) => () => close(handle)),
      () => code.reset(),
      () => mcpInstalled,
      () => toolsLifecycle?.close(),
      () => options.onDispose?.(),
    ], "Nanocodex host disposal failed", disposal));
    return disposal;
  }

  toolsLifecycle?.claim();
  return Object.freeze({
    ready: async () => { await Promise.all([filesystem, mcpInstalled]); },
    retain() {
      if (disposal) throw new Error("Nanocodex host is already disposed");
      references += 1;
    },
    release() {
      if (references > 0) references -= 1;
      return references === 0 ? dispose() : Promise.resolve();
    },
    connect,
    httpOpen,
    httpHeaders,
    send,
    next,
    close,
    sleep: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
    executeCode: code.executeCodeObserved,
    waitCode: code.waitCodeObserved,
    beginCodeTurn: code.beginTurn,
    cancelCodeTurn: code.cancelTurn,
    nextCodeUpdate: code.nextCodeUpdate,
    executeTool: code.executeTool,
    bindSubagentSession: code.bindSubagentSession,
    cancelCode: code.cancel,
    toolMode: () => toolMode,
    toolDefinitions: code.toolDefinitions,
    releaseSession: code.releaseSession,
    emitEvent: onEvent,
    reset: code.reset,
    dispose,
  });
}

function queueState(socket) {
  return {
    socket,
    connecting: false,
    reject: undefined,
    queue: [],
    queuedBytes: 0,
    waiter: undefined,
    intentionallyClosed: false,
    overflowed: false,
    managed: false,
  };
}

function readHandshakeRejection(response, finish) {
  const chunks = [];
  let bytes = 0;
  let truncated = false;
  let settled = false;
  const complete = (error) => {
    if (settled) return;
    settled = true;
    if (error) {
      finish(error);
      return;
    }
    const body = Buffer.concat(chunks).toString("utf8") + (truncated ? "…" : "");
    const rejection = new Error(
      `WebSocket handshake was rejected with HTTP ${response.statusCode}`,
    );
    rejection.status = response.statusCode;
    rejection.body = body || "empty response body";
    const retryAfter = Number(header(response.headers, "retry-after"));
    if (Number.isFinite(retryAfter) && retryAfter >= 0) rejection.retryAfter = retryAfter;
    finish(rejection);
  };
  response.on("data", (chunk) => {
    if (settled || truncated) return;
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const remaining = MAX_HTTP_ERROR_BYTES - bytes;
    if (remaining <= 0) {
      truncated = true;
      complete();
      return;
    }
    const retained = value.subarray(0, remaining);
    chunks.push(retained);
    bytes += retained.byteLength;
    if (retained.byteLength < value.byteLength) {
      truncated = true;
      complete();
    }
  });
  response.once("end", () => complete());
  response.once("aborted", () => complete(new Error("WebSocket handshake response was aborted")));
  response.once("error", (error) => complete(error));
  response.once("close", () => {
    if (!response.complete) complete(new Error("WebSocket handshake response closed early"));
  });
}

function destroyWebSocket(socket, ...httpObjects) {
  const reset = httpObjects.at(-1) === true;
  if (reset) httpObjects = httpObjects.slice(0, -1);
  const sockets = new Set([
    socket?._socket,
    socket?._req?.socket,
    ...httpObjects.map((object) => object?.socket),
  ]);
  for (const underlying of sockets) {
    if (!underlying || underlying.destroyed) continue;
    try {
      if (reset && typeof underlying.resetAndDestroy === "function") underlying.resetAndDestroy();
      else underlying.destroy();
    } catch {}
  }
  if (!reset) {
    try {
      if (typeof socket.terminate === "function") socket.terminate();
      else socket.close();
    } catch {}
  }
}

function header(headers, name) {
  const value = headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function messageBytes(message) {
  return utf8ByteLength(message.kind === "text" ? message.text : JSON.stringify(message));
}

function errorMessage(error) {
  return error && (error.stack || error.message) || String(error);
}
