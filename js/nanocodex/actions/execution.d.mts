import type { Agent, ExecutionSnapshot, ExecutionState, Turn } from "../types.mjs";

/** Returns a bounded, engine-owned view of accepted execution state. */
export function snapshot(agent: Agent<object>): Promise<ExecutionSnapshot>;

/** Looks up one accepted execution by stable identity, or returns null. */
export function state(
  agent: Agent<object>,
  operationId: string,
): Promise<ExecutionState | null>;

/** Cancels one unfinished execution by stable identity. */
export function cancel(agent: Agent<object>, operationId: string): Promise<void>;

/** Resumes retained prompt input through the existing engine and durability guards. */
export function resume(agent: Agent<object>, operationId: string): Promise<Turn>;
