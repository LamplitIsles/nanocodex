import type {
  AgentLifecycle,
  AgentOptions,
  CodeEvaluator,
  DefaultAgent,
  DurabilityStore,
  McpServers,
  ToolConfiguration,
  ToolProvider,
} from "../types.mjs";
import type { ManagedTransport, ResponsesTransport } from "./Transport.mjs";
import type { Tool as SubagentTool } from "../runtime/subagents.mjs";
import type { Workspace } from "./workspace.mjs";
import type { Tools } from "../tools/Tools.mjs";

export type Agent = DefaultAgent;
type ToolExposureOptions =
  | { mcp?: false | undefined; toolMode?: "code" | "direct" | undefined }
  | { mcp: McpServers; toolMode?: "code" | undefined };

/** Creates a Node-hosted Rust/WASM Agent. */
export function create(options: create.ManagedOptions): Promise<AgentLifecycle>;
export function create(options: create.Options): Promise<create.ReturnType>;
export declare namespace create {
  type ManagedOptions = Readonly<{
    transport: ManagedTransport;
    tools?: Tools | undefined;
  }>;
  type Options = AgentOptions & ToolExposureOptions & {
    /** Enable built-in subagents (default true). False conflicts with Subagents.create(). */
    subagents?: boolean | undefined;
    codeEvaluator?: CodeEvaluator | undefined;
    /** Caller-owned rooted filesystem mounted through standard workspace tools. */
    filesystem?: Workspace | undefined;
    module?: unknown;
    /** Dynamic tools refreshed by the current execution-context callback. */
    toolProviders?: readonly ToolProvider[];
    transport: ResponsesTransport;
  } & (
    | {
      durability?: undefined;
      durabilityId?: undefined;
      tools?: ToolConfiguration<SubagentTool> | undefined;
    }
    | {
      durability: DurabilityStore;
      durabilityId: string;
      /** The root remains durable; clean subagent children are in-memory. */
      tools?: ToolConfiguration<SubagentTool> | undefined;
    }
  );
  type ReturnType = Agent;
}
