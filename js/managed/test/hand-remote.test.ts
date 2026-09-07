import { createExecutionContext, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { AccountHostedTools } from "../src/account-hosted-tools";
import worker from "../src/index";
import type { Principal } from "../src/account-auth";

const A = "11111111-1111-4111-8111-111111111191";
const B = "22222222-2222-4222-8222-222222222292";
const surface = { id: "screen", name: "Screen", kind: "desktop", width: 1920, height: 1080, controllable: true };
const namespace = () => (env as unknown as { NANOCODEX_ACCOUNT_TOOLS: DurableObjectNamespace<AccountHostedTools> }).NANOCODEX_ACCOUNT_TOOLS;
const headers = (owner = A) => ({ "x-nanocodex-owner-id": owner });

function next(socket: WebSocket): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.removeEventListener("message", receive); reject(new Error("No remote signal")); }, 2000);
    function receive(event: MessageEvent) { clearTimeout(timer); socket.removeEventListener("message", receive); resolve(JSON.parse(String(event.data))); }
    socket.addEventListener("message", receive);
  });
}
async function host(machine: string, owner = A) {
  const stub = namespace().getByName(owner);
  const response = await stub.fetch("https://account-tools.internal/hands/host", { headers: { ...headers(owner), upgrade: "websocket" } });
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  const ready = next(socket); socket.accept();
  const state = await ready;
  const published = next(socket);
  socket.send(JSON.stringify({ type: "catalog", machine_id: machine, machine_name: machine, surfaces: [surface] }));
  expect(await published).toEqual({ type: "published", generation: state.generation });
  return { stub, socket, state };
}

describe("interactive hand signaling on a real Durable Object", () => {
  it("preserves device inventory while the account publishes remote screens", async () => {
    const owner = crypto.randomUUID();
    const { socket, state } = await host("remote-only", owner);
    const principal: Principal = {
      kind: "api_key", userId: owner, organizationId: crypto.randomUUID(), teamId: crypto.randomUUID(),
      role: "owner", subjectId: `user:${owner}`, credentialId: "test", authorizationEpoch: 1,
      capabilities: ["agents:read", "agents:write", "tools:use"],
    };
    const call = (path: string, actor = principal) => worker.fetch(
      new Request("https://nanocodex.example/v1/account/hands" + path),
      env as Parameters<typeof worker.fetch>[1], createExecutionContext(), actor,
    );
    try {
      expect(await (await call("")).json()).toEqual({ data: [] });
      expect(await (await call("/screens")).json()).toEqual({ surfaces: [{
        ...surface, machine_id: "remote-only", machine_name: "remote-only", generation: state.generation,
      }] });
      expect(await (await call("/screens", { ...principal, userId: crypto.randomUUID() })).json()).toEqual({ surfaces: [] });
      expect((await call("/screens", { ...principal, capabilities: ["agents:read"] })).status).toBe(403);
    } finally { socket.close(1000, "Done"); }
  });

  it("fences VM publishers by machine, route, role, and allocation lease", async () => {
    const stub = namespace().getByName(A);
    const scope = { machineId: "vm:allocated", routeId: "vm-host:allocation:1", expiresAt: Date.now() + 20_000 };
    const scopedHeaders = (value = scope) => ({ ...headers(), "x-nanocodex-capabilities": '["agents:write"]',
      "x-nanocodex-remote-vm": JSON.stringify(value) });
    const open = async () => {
      const response = await stub.fetch("https://account-tools.internal/hands/host", { headers: { ...scopedHeaders(), upgrade: "websocket" } });
      expect(response.status).toBe(101);
      const socket = response.webSocket!, pending = next(socket); socket.accept();
      return { socket, state: await pending };
    };
    const wrong = await open();
    const closed = new Promise<CloseEvent>(resolve => wrong.socket.addEventListener("close", resolve, { once: true }));
    wrong.socket.send(JSON.stringify({ type: "catalog", machine_id: "another-machine", machine_name: "VM", surfaces: [{ ...surface, kind: "vm" }] }));
    expect((await closed).code).toBe(1008);
    const vm = await open();
    expect(vm.state.expires_at).toBe(scope.expiresAt);
    const published = next(vm.socket);
    vm.socket.send(JSON.stringify({ type: "catalog", machine_id: scope.machineId, machine_name: "VM", surfaces: [{ ...surface, kind: "vm" }] }));
    await published;
    const ordinary = await host("personal-mac");
    const renew = (id: string, auth: Record<string, string>) => stub.fetch("https://account-tools.internal/hands/renew", {
      method: "POST", headers: auth, body: JSON.stringify({ connection_id: id }),
    });
    expect((await renew(ordinary.state.connection_id, scopedHeaders())).status).toBe(403);
    expect((await renew(vm.state.connection_id, scopedHeaders({ ...scope, routeId: "vm-host:allocation:2" }))).status).toBe(403);
    expect((await renew(vm.state.connection_id, { ...headers(), "x-nanocodex-capabilities": '["agents:write"]' })).status).toBe(403);
    const renewed = next(vm.socket);
    expect((await renew(vm.state.connection_id, scopedHeaders())).status).toBe(200); await renewed;
    expect((await stub.fetch("https://account-tools.internal/hands/screens", { headers: scopedHeaders() })).status).toBe(403);
    vm.socket.close(); ordinary.socket.close();
  });

  it("routes SDP and ICE to the exact surface generation without storing media", async () => {
    const { stub, socket, state } = await host("mac");
    const list = await stub.fetch("https://account-tools.internal/hands/screens", { headers: headers() });
    expect(await list.json()).toMatchObject({ surfaces: [{ ...surface, machine_id: "mac", generation: state.generation }] });
    const joined = next(socket);
    const response = await stub.fetch(`https://account-tools.internal/hands/view?machine_id=mac&surface_id=screen&generation=${state.generation}`, { headers: { ...headers(), upgrade: "websocket" } });
    expect(response.status).toBe(101);
    const viewer = response.webSocket!;
    const viewerReady = next(viewer); viewer.accept(); await viewerReady;
    const connection = await joined;
    expect(connection).toMatchObject({ type: "viewer", surface_id: "screen", generation: state.generation });
    const offered = next(viewer);
    socket.send(JSON.stringify({ type: "signal", viewer_id: connection.viewer_id, signal: { type: "offer", sdp: "v=0\r\n" } }));
    expect(await offered).toEqual({ type: "signal", signal: { type: "offer", sdp: "v=0\r\n" } });
    const answered = next(socket);
    viewer.send(JSON.stringify({ type: "signal", signal: { type: "answer", sdp: "v=0\r\n" } }));
    expect(await answered).toEqual({ type: "signal", viewer_id: connection.viewer_id, signal: { type: "answer", sdp: "v=0\r\n" } });
    const renewed = next(viewer);
    const renewal = await stub.fetch("https://account-tools.internal/hands/renew", { method: "POST", headers: headers(), body: JSON.stringify({ connection_id: connection.viewer_id }) });
    expect(renewal.status).toBe(200); expect(await renewed).toMatchObject({ type: "renewed" });
    const left = next(socket); viewer.close();
    expect(await left).toEqual({ type: "viewer_left", viewer_id: connection.viewer_id });
    socket.close();
  });

  it("denies another owner and never switches a stale viewer to a replacement host", async () => {
    const first = await host("replace");
    const forbidden = await first.stub.fetch("https://account-tools.internal/hands/screens", { headers: headers(B) });
    expect(forbidden.status).toBe(404);
    const second = await host("replace");
    expect(second.state.generation).not.toBe(first.state.generation);
    const stale = await first.stub.fetch(`https://account-tools.internal/hands/view?machine_id=replace&surface_id=screen&generation=${first.state.generation}`, { headers: { ...headers(), upgrade: "websocket" } });
    expect(stale.status).toBe(409);
    const other = namespace().getByName(B);
    const crossAccount = await other.fetch(`https://account-tools.internal/hands/view?machine_id=replace&surface_id=screen&generation=${second.state.generation}`, { headers: { ...headers(B), upgrade: "websocket" } });
    expect(crossAccount.status).toBe(409);
    second.socket.close();
  });

  it("rejects viewer attempts to publish SDP offers or choose another recipient", async () => {
    const { stub, socket, state } = await host("isolate");
    const joined = next(socket);
    const response = await stub.fetch(`https://account-tools.internal/hands/view?machine_id=isolate&surface_id=screen&generation=${state.generation}`, { headers: { ...headers(), upgrade: "websocket" } });
    const viewer = response.webSocket!;
    const ready = next(viewer); viewer.accept(); await ready; await joined;
    const closed = new Promise<CloseEvent>(resolve => viewer.addEventListener("close", resolve, { once: true }));
    viewer.send(JSON.stringify({ type: "signal", viewer_id: "someone-else", signal: { type: "offer", sdp: "v=0" } }));
    expect((await closed).code).toBe(1008);
    socket.close();
  });

  it("lets a host close only its own viewer without interrupting another host", async () => {
    const first = await host("close-first"), second = await host("close-second");
    const joined = next(second.socket);
    const response = await second.stub.fetch(`https://account-tools.internal/hands/view?machine_id=close-second&surface_id=screen&generation=${second.state.generation}`, { headers: { ...headers(), upgrade: "websocket" } });
    const viewer = response.webSocket!;
    const ready = next(viewer); viewer.accept(); await ready;
    const connection = await joined;
    first.socket.send(JSON.stringify({ type: "close_viewer", viewer_id: connection.viewer_id }));
    const pong = next(viewer); viewer.send(JSON.stringify({ type: "ping" }));
    expect(await pong).toEqual({ type: "pong" });
    const closed = new Promise<CloseEvent>(resolve => viewer.addEventListener("close", resolve, { once: true }));
    second.socket.send(JSON.stringify({ type: "close_viewer", viewer_id: connection.viewer_id }));
    expect((await closed).code).toBe(1008);
    first.socket.close(); second.socket.close();
  });
});
