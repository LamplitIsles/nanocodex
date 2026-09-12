import type { Tool, Workspace } from "nanocodex-tools";

/** Create an apply_patch tool using the canonical Rust/WASM planner. */
export function applyPatch(options: { workspace: Workspace }): Tool;
