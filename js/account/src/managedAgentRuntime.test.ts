import type { AgentEvent } from "nanocodex-react/agent";
import type { ManagedEvent } from "nanocodex/managed";
import { appQueryClient, clearOtherAccountQueries } from "./queryClient.ts";
import assert from "node:assert/strict";
import test from "node:test";
import {
  listManagedConversations,
  loadManagedConversationSelection,
  terminalEvent,
  managedTerminalAgent,
  type ManagedTerminalSource,
} from "./managedAgentRuntime.ts";

// Detached mock watchers can outlive removal; avoid real GC timers in Node.
appQueryClient.setDefaultOptions({ ...appQueryClient.getDefaultOptions(), queries: { ...appQueryClient.getDefaultOptions().queries, gcTime: Infinity } });

const FIRST_AGENT_ID = "018f0000-0000-7000-8000-000000000001";
const SECOND_AGENT_ID = "018f0000-0000-7000-8000-000000000002";
const FORBIDDEN_AGENT_ID = "018f0000-0000-7000-8000-000000000003";

test("terminal projection preserves the persisted event time for command elapsed duration", () => {
  const projected = terminalEvent({
    cursor: "26", createdAt: 1788766853390, turnId: "cargo-turn", type: "event",
    data: {
      type: "event", cursor: "26", created_at: 1788766853390, turn_id: "cargo-turn",
      event: { protocol_version: 1, request_id: "internal", seq: 1, type: "tool.call",
        payload: { call_id: "cargo", tool: "exec_command", arguments: { cmd: "cargo test" } } },
    },
  }, "public-session", undefined, 26);
  assert.equal(projected?.payload.managed_event_created_at, 1788766853390);
  assert.equal(projected?.payload.managed_event_cursor, "26");
  assert.equal(projected?.payload.turn_id, "cargo-turn");
});

test("an exact agent route survives a successful list cached before another client created it", async (t) => {
  t.after(() => appQueryClient.clear());
  const originalLocation = Object.getOwnPropertyDescriptor(globalThis, "location");
  const originalFetch = globalThis.fetch;
  Object.defineProperty(globalThis, "location", {
    configurable: true,
    value: new URL("https://account.example"),
  });
  let agentIds = [FIRST_AGENT_ID];
  let listCalls = 0;
  const exactCalls: string[] = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    const path = new URL(request.url).pathname;
    if (request.method === "GET" && path === "/v1/agents") {
      listCalls += 1;
      return Response.json({
        data: agentIds,
        summaries: Object.fromEntries(agentIds.map((id, index) => [id, {
          title: `Agent ${index + 1}`,
          created_at: index + 1,
          updated_at: agentIds.length - index,
          turn_count: index,
        }])),
      });
    }
    const exactId = decodeURIComponent(path.slice("/v1/agents/".length));
    exactCalls.push(exactId);
    if (request.method === "GET" && agentIds.includes(exactId)) return Response.json({});
    return Response.json(
      { error: "forbidden", message: "That exact agent is not available to this account." },
      { status: 403 },
    );
  };
  t.after(() => {
    globalThis.fetch = originalFetch;
    if (originalLocation) Object.defineProperty(globalThis, "location", originalLocation);
    else Reflect.deleteProperty(globalThis, "location");
  });

  const initial = await listManagedConversations("stale-list-client");
  assert.deepEqual(initial.map(({ id }) => id), [FIRST_AGENT_ID]);
  agentIds = [SECOND_AGENT_ID, FIRST_AGENT_ID];

  const stale = await listManagedConversations("stale-list-client");
  assert.deepEqual(stale.map(({ id }) => id), [FIRST_AGENT_ID]);
  assert.equal(listCalls, 1);

  const routed = await loadManagedConversationSelection({
    accountId: "stale-list-client",
    routeAgentId: SECOND_AGENT_ID,
    retainedAgentId: FIRST_AGENT_ID,
    hasCredential: true,
  });
  assert.equal(routed.selectedId, SECOND_AGENT_ID);
  assert.equal(routed.replaceRoute, false);
  assert.deepEqual(routed.conversations.map(({ id }) => id), [SECOND_AGENT_ID, FIRST_AGENT_ID]);
  assert.deepEqual(exactCalls, [SECOND_AGENT_ID]);
  assert.equal(listCalls, 1);

  const augmented = await listManagedConversations("stale-list-client");
  assert.deepEqual(augmented.map(({ id }) => id), [SECOND_AGENT_ID, FIRST_AGENT_ID]);
  assert.equal(listCalls, 1);

  const refreshed = await listManagedConversations("stale-list-client", { refresh: true });
  assert.deepEqual(refreshed.map(({ id }) => id), [SECOND_AGENT_ID, FIRST_AGENT_ID]);
  assert.equal(listCalls, 2);

  await assert.rejects(
    loadManagedConversationSelection({
      accountId: "stale-list-client",
      routeAgentId: FORBIDDEN_AGENT_ID,
      retainedAgentId: FIRST_AGENT_ID,
      hasCredential: true,
    }),
    /That exact agent is not available to this account/,
  );
  assert.deepEqual(exactCalls, [SECOND_AGENT_ID, FORBIDDEN_AGENT_ID]);
});

function historyFixture(id: string) {
  const event = (cursor: string, text: string): ManagedEvent => ({
    cursor, createdAt: 1, turnId: `turn-${cursor}`, type: "turn_accepted",
    data: { cursor, created_at: 1, turn_id: `turn-${cursor}`, type: "turn_accepted", id: `turn-${cursor}`, input: text, replayed: false },
  });
  const events = [event("1", `History for ${id}`)];
  const cursors: string[] = [];
  let pages = 0;
  const source: ManagedTerminalSource = {
    id, type: "managed",
    events: {
      async page() { pages++; return { data: [...events], hasMore: false, latestCursor: events.at(-1)!.cursor }; },
      async *watch({ cursor = "0", signal } = {}) {
        cursors.push(cursor);
        for (const envelope of events) if (Number(envelope.cursor) > Number(cursor)) yield envelope;
        if (!signal?.aborted) await new Promise<void>((resolve) => signal?.addEventListener("abort", () => resolve(), { once: true }));
      },
    },
    turn: { prompt() { throw new Error("not used"); } },
  };
  return { source, cursors, get pages() { return pages; }, append: (text: string) => events.push(event(String(events.length + 1), text)) };
}

async function watchHistory(source: ManagedTerminalSource, accountId: string) {
  const watcher = managedTerminalAgent(source, { accountId }).events.watch();
  const history = await new Promise<readonly AgentEvent[]>((resolve) => watcher.onHistory!(resolve));
  return { watcher, history };
}

test("A → B → A restores cached history immediately and resumes after A's last cursor", async (t) => {
  t.after(() => appQueryClient.clear());
  const a = historyFixture(FIRST_AGENT_ID);
  const b = historyFixture(SECOND_AGENT_ID);
  const first = await watchHistory(a.source, "account-a");
  first.watcher.off();
  const second = await watchHistory(b.source, "account-a");
  second.watcher.off();
  a.append("Arrived while viewing B");
  const returning = managedTerminalAgent(a.source, { accountId: "account-a" }).events.watch();
  let immediate: readonly AgentEvent[] | undefined;
  returning.onHistory!((events) => { immediate = events; });
  assert.deepEqual(immediate, first.history);
  const live = await new Promise<AgentEvent>((resolve) => returning.onEvent(resolve));
  assert.equal(live.payload.text, "Arrived while viewing B");
  returning.off();
  assert.equal(a.pages, 1);
  assert.equal(b.pages, 1);
  assert.deepEqual(a.cursors, ["1", "1"]);
  const final = await watchHistory(a.source, "account-a");
  assert.equal(final.history.filter((event) => event.payload.text === "Arrived while viewing B").length, 1);
  final.watcher.off();
  assert.equal(a.cursors.at(-1), "2");
});

test("account changes discard thread snapshots, including a watcher detached after cache removal", async (t) => {
  t.after(() => appQueryClient.clear());
  const source = historyFixture(FIRST_AGENT_ID);
  const old = await watchHistory(source.source, "account-a");
  clearOtherAccountQueries(appQueryClient, "account-b");
  old.watcher.off();
  assert.equal(appQueryClient.getQueryCache().findAll({ queryKey: ["account", "account-a"] }).length, 0);
  const next = await watchHistory(source.source, "account-b");
  next.watcher.off();
  assert.equal(source.pages, 2);
});
