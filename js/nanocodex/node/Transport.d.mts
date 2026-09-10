import type {
  ChatGptSubscriptionHandle,
  MppSession,
} from "../types.mjs";
import type { Options as ManagedClientOptions } from "../managed/Agent.mjs";

declare const responsesTransport: unique symbol;
declare const managedTransport: unique symbol;

export type ResponsesTransport = Readonly<{
  [responsesTransport]: true;
}>;
export type ManagedTransport = Readonly<{ [managedTransport]: true }>;
export type Transport = ResponsesTransport | ManagedTransport;

type EndpointOptions = Readonly<{
  /** HTTPS `/v1` base used for Node's pre-output SSE fallback. */
  apiBaseUrl?: string | undefined;
  /** Preferred Responses WebSocket endpoint. */
  websocketUrl?: string | undefined;
  /** Whether the Node host should probe the WebSocket with a non-generating request. */
  websocketWarmup?: boolean | undefined;
}>;

export function openAi(options: EndpointOptions & Readonly<{
  apiKey: string;
}>): ResponsesTransport;

export function chatGpt(options: EndpointOptions & Readonly<{
  subscription: ChatGptSubscriptionHandle;
}>): ResponsesTransport;

export function mpp(options: EndpointOptions & Readonly<{
  session: MppSession;
}>): ResponsesTransport;

export type ManagedIdentity =
  | Readonly<{ create: true; id?: never }>
  | Readonly<{ id: string; create?: never }>;

/** Account-authenticated durable Agent transport with explicit create/open identity. */
export function managed(options: ManagedClientOptions & Readonly<{
  agent: ManagedIdentity;
}>): ManagedTransport;
