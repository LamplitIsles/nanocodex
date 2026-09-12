//! Complete typed lifecycle events emitted around Responses operations.

mod data;
pub(crate) mod stream;

#[doc(inline)]
#[cfg(feature = "client")]
pub use data::OpenAiEvent;
#[doc(inline)]
pub use data::{
    AgentEventData, AssistantDelta, AssistantEvent, AssistantMessage, CompactionCompleted,
    CompactionFailed, CompactionInstalledItem, CompactionItemIdentity, CompactionReplaced,
    CompactionSessionContext, CompactionStarted, ContextEvent, EventUsage, ExecutionStateChanged,
    ModelCallCompleted, ModelCallFailed, ModelCallStarted, ModelEvent, ModelWarmupCompleted,
    ModelWarmupFailed, ModelWarmupStarted, ReasoningEvent, ReasoningSummaryDelta, RunError,
    RunEvent, RunMetrics, RunStarted, RunStatus, RunSteered, RunTerminal, ToolCall, ToolEvent,
    ToolResultEvent, ToolStatus, TransportEvent,
};
#[doc(inline)]
pub use stream::{
    AGENT_EVENT_PROTOCOL_VERSION, AgentEvent, AgentEventKind, AgentEventPublisher, AgentEvents,
    EventError,
};
#[doc(hidden)]
pub use stream::{AgentEventTiming, TimedAgentEvent, monotonic_now_ns};

/// Lossless JSON representation for execution counters shared with JavaScript.
#[doc(hidden)]
pub mod decimal_u64 {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &u64, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
        let encoded = String::deserialize(deserializer)?;
        let value: u64 = encoded.parse().map_err(serde::de::Error::custom)?;
        if encoded != value.to_string() {
            return Err(serde::de::Error::custom("expected a canonical decimal u64"));
        }
        Ok(value)
    }
}
