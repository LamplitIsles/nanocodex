import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Agent, Transport, Workspace, applyPatch } from "../node/index.mjs";
import { messageReader, sendCompleted, sendFinal, startResponsesServer } from "./support/responses.mjs";

const patch = body => `*** Begin Patch\n${body}\n*** End Patch`;

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "naco-patch-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const workspace = await Workspace.open({ path: join(directory, "workspace") });
  return { directory, workspace, tool: applyPatch({ workspace }) };
}

test("Node patch uses Rust add, update, move and delete planning", async t => {
  const { workspace, tool } = await fixture(t);
  await tool.handler(patch("*** Add File: a.txt\n+one\n+two"));
  await tool.handler(patch("*** Update File: a.txt\n*** Move to: nested/b.txt\n@@\n-two\n+three"));
  assert.equal(new TextDecoder().decode(await workspace.readFile("nested/b.txt")), "one\nthree\n");
  await assert.rejects(workspace.readFile("a.txt"), /ENOENT/);
  await tool.handler(patch("*** Delete File: nested/b.txt"));
  await assert.rejects(workspace.readFile("nested/b.txt"), /ENOENT/);
});

test("invalid hunks, escaping paths, symlinks and cancellation do not edit files", async t => {
  const { directory, workspace, tool } = await fixture(t);
  await workspace.writeFile("a.txt", "original\n");
  await assert.rejects(tool.handler(patch("*** Add File: untouched.txt\n+hello\n*** Update File: a.txt\n@@\n-missing\n+bad")));
  await assert.rejects(workspace.readFile("untouched.txt"), /ENOENT/);
  await assert.rejects(tool.handler(patch("*** Add File: untouched.txt\n+hello\n*** Add File: ../outside.txt\n+bad")));
  await assert.rejects(workspace.readFile("untouched.txt"), /ENOENT/);
  const outside = join(directory, "outside.txt");
  await writeFile(outside, "outside\n");
  await symlink(outside, join(directory, "workspace/link.txt"));
  await assert.rejects(tool.handler(patch("*** Update File: link.txt\n@@\n-outside\n+bad")), /symbolic link/);
  assert.equal(await readFile(outside, "utf8"), "outside\n");
  await assert.rejects(tool.handler(patch("*** Delete File: a.txt"), { signal: AbortSignal.abort() }));
  assert.equal(new TextDecoder().decode(await workspace.readFile("a.txt")), "original\n");
});

test("source paths are validated before calling a custom workspace", async () => {
  const reads = [];
  const tool = applyPatch({ workspace: {
    root: "/workspace",
    async readFile(path) { reads.push(path); return new TextEncoder().encode("original\n"); },
    async writeFile() { assert.fail("unexpected write"); },
    async remove() { assert.fail("unexpected delete"); },
  } });
  for (const path of ["../secret.txt", "/outside/secret.txt"]) {
    await assert.rejects(tool.handler(patch(`*** Update File: ${path}\n@@\n-original\n+changed`)), /escape|within/);
  }
  assert.deepEqual(reads, []);
});

for (const nested of [false, true]) {
  test(`Node WASM ${nested ? "nested code mode" : "direct"} patch edits the supplied workspace`, { timeout: 15000 }, async t => {
    const { workspace, tool } = await fixture(t);
    const server = await startResponsesServer();
    t.after(() => server.close());
    const agent = await Agent.create({
      model: "gpt-5.6-luna", subagents: false,
      instructions: "Isolated patch fixture",
      tools: { apply_patch: tool },
      transport: Transport.openAi({ apiKey: "fixture", websocketUrl: server.url, websocketWarmup: false }),
    });
    t.after(async () => { await agent.session.shutdown(); agent.dispose(); });
    const turn = agent.turn.prompt({ input: "edit fixture" });
    const outcome = turn.result();
    outcome.catch(() => {});
    const socket = await server.nextConnection();
    const reader = messageReader(socket);
    const initial = await reader.next();
    assert.ok(initial.input.flatMap(item => item.tools ?? []).some(tool => tool.name === "apply_patch" && tool.type === "custom"));
    const input = patch("*** Add File: result.txt\n+from Rust");
    sendCompleted(socket, "patch-response", [{
      type: "custom_tool_call", call_id: "patch-call", name: nested ? "exec" : "apply_patch",
      input: nested ? `text(await tools.apply_patch(${JSON.stringify(input)}));` : input,
    }]);
    const continuation = await reader.next();
    assert.match(JSON.stringify(continuation.input), /Success/);
    assert.equal(new TextDecoder().decode(await workspace.readFile("result.txt")), "from Rust\n");
    sendFinal(socket, "done-response", "done");
    const result = await outcome;
    assert.equal(result.finalMessage, "done");
    result.dispose(); turn.dispose();
  });
}
