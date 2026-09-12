import { createRequire } from "node:module";
import { resolveWorkspacePath } from "../runtime/workspace.mjs";

const require = createRequire(import.meta.url);

/** A host tool backed by the canonical Rust/WASM patch planner. */
export function applyPatch({ workspace }) {
  let queue = Promise.resolve();
  return {
    description: "Apply a patch to the workspace using the canonical Rust planner.",
    parameters: { type: "object", additionalProperties: false },
    handler(input, context) {
      const pending = queue.then(async () => {
        if (typeof input !== "string") throw new TypeError("apply_patch requires a raw string input");
        context?.signal?.throwIfAborted();
        const { requiredPatchFiles, planWorkspacePatch } = require("../pkg-node/nanocodex.js");
        const files = Object.create(null);
        for (const path of JSON.parse(requiredPatchFiles(input))) {
          resolveWorkspacePath(workspace.root, path);
          files[path] = new TextDecoder("utf-8", { fatal: true }).decode(await workspace.readFile(path));
          context?.signal?.throwIfAborted();
        }
        const plan = JSON.parse(planWorkspacePatch(input, JSON.stringify(files)));
        // Check every destination before the first mutation, including add/move paths.
        for (const operation of plan.operations) resolveWorkspacePath(workspace.root, operation.path);
        const applied = [];
        try {
          for (const operation of plan.operations) {
            context?.signal?.throwIfAborted();
            if (operation.type === "write") await workspace.writeFile(operation.path, operation.contents);
            else await workspace.remove(operation.path);
            applied.push(operation.path);
          }
        } catch (error) {
          throw new Error(`Patch application failed after ${JSON.stringify(applied)}: ${error.message}`, { cause: error });
        }
        return plan.summary;
      });
      queue = pending.catch(() => {});
      return pending;
    },
  };
}
