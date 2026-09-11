//! Host-owned instruction selection for client-side context compaction.

use std::{future::Future, pin::Pin, sync::Arc};

use serde::Serialize;

use nanocodex_oai_api::{
    __private::compaction::CompactionInstallation,
    responses::{ContentItem, MessageRole, ResponseItem},
};

use crate::{AgentSessionContext, NanocodexError, Result};

/// The lifecycle boundary at which a compaction was requested.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionPhase {
    /// Compaction before a new user turn is sent.
    PreTurn,
    /// Compaction while continuing a model turn or after tool execution.
    MidTurn,
}

/// The reason the current compaction operation was started.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionTrigger {
    /// An explicit maintenance request from the embedding host.
    Manual,
    /// Automatic pressure or provider-overflow recovery.
    Automatic,
}

/// Minimal operation metadata supplied to a host instruction resolver.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct CompactionInstructionContext {
    /// Model-call boundary at which the operation was admitted.
    pub after_model_call_index: u32,
    /// Whether the operation is before a turn or inside a continuation.
    pub phase: CompactionPhase,
    /// Whether the operation was explicit or automatic.
    pub trigger: CompactionTrigger,
    /// Estimated active context before summary generation.
    pub active_context_tokens: u64,
    /// Automatic threshold that admitted the operation.
    pub auto_compact_token_limit: u64,
}

#[cfg(not(target_family = "wasm"))]
/// Boxed asynchronous result returned by a compaction instruction resolver.
pub type CompactionInstructionFuture =
    Pin<Box<dyn Future<Output = Result<String>> + Send + 'static>>;

#[cfg(target_family = "wasm")]
/// Boxed asynchronous result returned by a compaction instruction resolver.
pub type CompactionInstructionFuture = Pin<Box<dyn Future<Output = Result<String>> + 'static>>;

/// Embedding-owned asynchronous selector for one custom compaction instruction.
pub trait CompactionInstructionResolver: 'static {
    /// Resolves the final instruction before Nanocodex starts summary generation.
    fn resolve(&self, context: CompactionInstructionContext) -> CompactionInstructionFuture;
}

#[cfg(not(target_family = "wasm"))]
impl<T> CompactionInstructionResolver for Arc<T>
where
    T: CompactionInstructionResolver + Send + Sync,
{
    fn resolve(&self, context: CompactionInstructionContext) -> CompactionInstructionFuture {
        (**self).resolve(context)
    }
}

pub(crate) fn validate_instruction(instruction: String) -> Result<Arc<str>> {
    if instruction.trim().is_empty() {
        return Err(NanocodexError::InvalidRequest(
            "compaction instruction resolver returned an empty instruction".to_owned(),
        ));
    }
    Ok(Arc::from(instruction))
}

/// Half-open range in the pre-compaction managed history.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CompactionRange {
    start: usize,
    end: usize,
}

impl CompactionRange {
    /// Returns the first removed item index.
    #[must_use]
    pub const fn start(&self) -> usize {
        self.start
    }

    /// Returns the exclusive end of the removed range.
    #[must_use]
    pub const fn end(&self) -> usize {
        self.end
    }
}

/// Stable identity for an item retained after a compaction replacement.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CompactionItemIdentity {
    index: usize,
    kind: String,
    id: Option<String>,
    call_id: Option<String>,
}

impl CompactionItemIdentity {
    /// Returns the item's pre-replacement history index.
    #[must_use]
    pub const fn index(&self) -> usize {
        self.index
    }

    /// Returns the stable Responses item kind.
    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }

    /// Returns the provider or client item ID when the item has one.
    #[must_use]
    pub fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }

    /// Returns the tool call ID when the item is a tool call or output.
    #[must_use]
    pub fn call_id(&self) -> Option<&str> {
        self.call_id.as_deref()
    }
}

/// Private result of one completed context replacement.
#[derive(Clone, Debug)]
pub struct CompactionOutcome {
    revision: u64,
    trigger: CompactionTrigger,
    summary: Option<String>,
    replaced_history: CompactionRange,
    retained_tail: Vec<CompactionItemIdentity>,
    context: AgentSessionContext,
}

/// Ordered event payload emitted at the exact custom replacement boundary.
#[derive(Serialize)]
pub(crate) struct CompactionReplacedEvent<'a> {
    pub(crate) after_model_call_index: u32,
    pub(crate) phase: CompactionPhase,
    pub(crate) revision: String,
    pub(crate) trigger: CompactionTrigger,
    pub(crate) summary: Option<&'a str>,
    pub(crate) replaced_history: &'a CompactionRange,
    pub(crate) retained_tail: &'a [CompactionItemIdentity],
    pub(crate) context: CompactionReplacedContext<'a>,
}

#[derive(Serialize)]
pub(crate) struct CompactionReplacedContext<'a> {
    pub(crate) workspace: &'a str,
    pub(crate) history: &'a [ResponseItem],
}

impl CompactionOutcome {
    pub(crate) fn pending(
        revision: u64,
        trigger: CompactionTrigger,
        summary: Option<String>,
        replaced_history: CompactionRange,
        retained_tail: Vec<CompactionItemIdentity>,
    ) -> Self {
        Self {
            revision,
            trigger,
            summary,
            replaced_history,
            retained_tail,
            context: AgentSessionContext::from_backend(String::new(), Vec::new()),
        }
    }

    pub(crate) fn with_context(mut self, context: AgentSessionContext) -> Self {
        self.context = context;
        self
    }

    pub(crate) fn event<'a>(
        &'a self,
        after_model_call_index: u32,
        phase: CompactionPhase,
    ) -> CompactionReplacedEvent<'a> {
        CompactionReplacedEvent {
            after_model_call_index,
            phase,
            revision: self.revision.to_string(),
            trigger: self.trigger,
            summary: self.summary.as_deref(),
            replaced_history: &self.replaced_history,
            retained_tail: &self.retained_tail,
            context: CompactionReplacedContext {
                workspace: self.context.workspace(),
                history: self.context.history(),
            },
        }
    }

    /// Returns the monotonic history-replacement revision.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Returns whether the replacement was explicitly requested or automatic.
    #[must_use]
    pub const fn trigger(&self) -> CompactionTrigger {
        self.trigger
    }

    /// Returns the generated private summary, when the custom path produced one.
    #[must_use]
    pub fn summary(&self) -> Option<&str> {
        self.summary.as_deref()
    }

    /// Returns the pre-compaction range replaced by the summary.
    #[must_use]
    pub const fn replaced_history(&self) -> &CompactionRange {
        &self.replaced_history
    }

    /// Returns the complete retained tail identities in provider order.
    #[must_use]
    pub fn retained_tail(&self) -> &[CompactionItemIdentity] {
        &self.retained_tail
    }

    /// Returns the complete model-visible context after this replacement.
    #[must_use]
    pub const fn context(&self) -> &AgentSessionContext {
        &self.context
    }
}

pub(crate) fn outcome_from_installation(
    installation: CompactionInstallation,
    revision: u64,
    trigger: CompactionTrigger,
    summary: Option<String>,
) -> CompactionOutcome {
    let retained_tail = installation
        .retained_tail
        .iter()
        .map(|(index, item)| item_identity(*index, item))
        .collect();
    CompactionOutcome::pending(
        revision,
        trigger,
        summary,
        CompactionRange {
            start: installation.replaced_start,
            end: installation.replaced_end,
        },
        retained_tail,
    )
}

pub(crate) fn summary_text(item: &ResponseItem) -> Option<String> {
    let ResponseItem::Message {
        role: MessageRole::Developer,
        content,
        ..
    } = item
    else {
        return None;
    };
    let text = content.iter().find_map(|content| match content {
        ContentItem::InputText { text } => Some(text),
        _ => None,
    })?;
    text.strip_prefix("<compacted-summary>\n")
        .and_then(|text| text.strip_suffix("\n</compacted-summary>"))
        .map(str::to_owned)
}

fn item_identity(index: usize, item: &ResponseItem) -> CompactionItemIdentity {
    let value = serde_json::to_value(item).unwrap_or_default();
    CompactionItemIdentity {
        index,
        kind: value
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        id: item.id().map(ToString::to_string),
        call_id: value
            .get("call_id")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    }
}
