export type SubagentToolContext = Readonly<{
  agentId: string;
  parentAgentId: string | null;
  sessionId: string;
  role: string;
  task: string;
}>;

export type ToolContext = Readonly<{
  callId: string;
  parentCallId: string;
  sessionId: string;
  model: string;
  signal: AbortSignal;
  subagent?: SubagentToolContext | undefined;
}>;

/** JSON Schema or other provider-owned JSON metadata used by a tool definition. */
export type ToolJson = Readonly<Record<string, unknown>>;

/** Grammar format for a Responses free-form custom tool. */
export type CustomToolFormat = Readonly<{
  type: "grammar";
  syntax: string;
  definition: string;
}>;

/** Exact function or grammar-constrained custom definition sent to the model. */
export type ToolDefinition =
  | Readonly<{
    type: "function";
    /** The router replaces this with the containing map or named-tool name. */
    name?: string | undefined;
    description: string;
    strict: boolean;
    defer_loading?: boolean | undefined;
    async?: boolean | undefined;
    parameters: ToolJson;
    output_schema?: ToolJson | undefined;
  }>
  | Readonly<{
    type: "custom";
    /** The router replaces this with the containing map or named-tool name. */
    name?: string | undefined;
    description: string;
    defer_loading?: boolean | undefined;
    async?: boolean | undefined;
    format: CustomToolFormat;
  }>;

export type Tool = Readonly<{
  description: string;
  supportsParallelToolCalls?: boolean | undefined;
  parameters?: Record<string, unknown> | undefined;
  outputSchema?: Record<string, unknown> | undefined;
  /** Optional provider-native definition; its name is canonicalized by the router. */
  definition?: ToolDefinition | undefined;
  handler(input: unknown, context: ToolContext): unknown | Promise<unknown>;
  releaseSession?(sessionId: string): void;
  dispose?(): void | Promise<void>;
}>;

export type NamedTool = Tool & Readonly<{ name: string }>;
export type ToolMap = Record<string, Tool>;

export type WorkspaceEntry = Readonly<{
  kind: "directory" | "file";
  modifiedAt?: number | undefined;
  path: string;
  size?: number | undefined;
}>;

export type Workspace = Readonly<{
  root: string;
  list(path?: string, options?: {
    recursive?: boolean | undefined;
    maxEntries?: number | undefined;
  }): Promise<readonly WorkspaceEntry[]>;
  readFile(path: string): Promise<Uint8Array>;
  writeFile(path: string, contents: string | ArrayBuffer | ArrayBufferView): Promise<void>;
  remove(path: string, options?: { recursive?: boolean | undefined }): Promise<void>;
  mkdir(path: string): Promise<void>;
}>;
