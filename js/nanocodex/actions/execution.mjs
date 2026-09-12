import {
  cancelExecution,
  resumeExecution,
  executionSnapshot,
  executionState,
} from "../internal.mjs";

export function snapshot(agent) {
  return executionSnapshot(agent);
}

export function state(agent, operationId) {
  return executionState(agent, operationId);
}

export function cancel(agent, operationId) {
  return cancelExecution(agent, operationId);
}

export function resume(agent, operationId) {
  return resumeExecution(agent, operationId);
}
